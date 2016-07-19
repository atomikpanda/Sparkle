//
//  AppInstaller.m
//  Sparkle
//
//  Created by Mayur Pawashe on 3/7/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import "AppInstaller.h"
#import "TerminationListener.h"
#import "SUInstaller.h"
#import "SULog.h"
#import "SUHost.h"
#import "SULocalizations.h"
#import "SUStandardVersionComparator.h"
#import "SUDSAVerifier.h"
#import "SUCodeSigningVerifier.h"
#import "SUMessageTypes.h"
#import "SUSecureCoding.h"
#import "SUInstallationInputData.h"
#import "SUUnarchiver.h"
#import "SUFileManager.h"
#import "SUInstallationInfo.h"
#import "SUAppcastItem.h"
#import "SUErrors.h"
#import "SUInstallerCommunicationProtocol.h"
#import "AgentConnection.h"
#import "SUInstallerAgentProtocol.h"

#ifdef _APPKITDEFINES_H
#error This is a "daemon-safe" class and should NOT import AppKit
#endif

#define FIRST_UPDATER_MESSAGE_TIMEOUT 7ull
#define RETRIEVE_PROCESS_IDENTIFIER_TIMEOUT 5ull

/*!
 * Terminate the application after a delay from launching the new update to avoid OS activation issues
 * This delay should be be high enough to increase the likelihood that our updated app will be launched up front,
 * but should be low enough so that the user doesn't ponder why the updater hasn't finished terminating yet
 */
static const NSTimeInterval SUTerminationTimeDelay = 0.5;

/*!
 * Show display progress UI after a delay from starting the final part of the installation.
 * This should be long enough so that we don't show progress for very fast installations, but
 * short enough so that we don't leave the user wondering why nothing is happening.
 */
static const NSTimeInterval SUDisplayProgressTimeDelay = 0.7;

@interface AppInstaller () <NSXPCListenerDelegate, SUInstallerCommunicationProtocol, AgentConnectionDelegate>

@property (nonatomic) NSXPCListener* xpcListener;
@property (nonatomic) NSXPCConnection *activeConnection;
@property (nonatomic) id<SUInstallerCommunicationProtocol> communicator;
@property (nonatomic) AgentConnection *agentConnection;
@property (nonatomic) BOOL receivedUpdaterPong;

@property (nonatomic, strong) TerminationListener *terminationListener;

@property (nonatomic, readonly, copy) NSString *hostBundleIdentifier;
@property (nonatomic, readonly) BOOL allowsInteraction;
@property (nonatomic) SUHost *host;
@property (nonatomic) SUInstallationInputData *installationData;
@property (nonatomic, assign) BOOL shouldRelaunch;
@property (nonatomic, assign) BOOL shouldShowUI;

@property (nonatomic) id<SUInstallerProtocol> installer;
@property (nonatomic) BOOL willCompleteInstallation;
@property (nonatomic) BOOL receivedInstallationData;

@property (nonatomic) dispatch_queue_t installerQueue;
@property (nonatomic) BOOL performedStage1Installation;
@property (nonatomic) BOOL performedStage2Installation;
@property (nonatomic) BOOL performedStage3Installation;

@property (nonatomic) NSUInteger agentConnectionCounter;

@end

@implementation AppInstaller

@synthesize xpcListener = _xpcListener;
@synthesize activeConnection = _activeConnection;
@synthesize communicator = _communicator;
@synthesize agentConnection = _agentConnection;
@synthesize receivedUpdaterPong = _receivedUpdaterPong;
@synthesize hostBundleIdentifier = _hostBundleIdentifier;
@synthesize allowsInteraction = _allowsInteraction;
@synthesize terminationListener = _terminationListener;
@synthesize host = _host;
@synthesize installationData = _installationData;
@synthesize shouldRelaunch = _shouldRelaunch;
@synthesize shouldShowUI = _shouldShowUI;
@synthesize installer = _installer;
@synthesize willCompleteInstallation = _willCompleteInstallation;
@synthesize receivedInstallationData = _receivedInstallationData;
@synthesize installerQueue = _installerQueue;
@synthesize performedStage1Installation = _performedStage1Installation;
@synthesize performedStage2Installation = _performedStage2Installation;
@synthesize performedStage3Installation = _performedStage3Installation;
@synthesize agentConnectionCounter = _agentConnectionCounter;

- (instancetype)initWithHostBundleIdentifier:(NSString *)hostBundleIdentifier allowingInteraction:(BOOL)allowsInteraction
{
    if (!(self = [super init])) {
        return nil;
    }
    
    _hostBundleIdentifier = [hostBundleIdentifier copy];
    
    _allowsInteraction = allowsInteraction;
    
    _xpcListener = [[NSXPCListener alloc] initWithMachServiceName:SUInstallerServiceNameForBundleIdentifier(hostBundleIdentifier)];
    _xpcListener.delegate = self;
    
    _agentConnection = [[AgentConnection alloc] initWithHostBundleIdentifier:hostBundleIdentifier delegate:self];
    
    return self;
}

- (BOOL)listener:(NSXPCListener *)__unused listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    SULog(@"Incoming connection: %@", newConnection);
    
    if (self.activeConnection != nil) {
        SULog(@"Rejecting multiple connections...");
        [newConnection invalidate];
        return NO;
    }
    
    self.activeConnection = newConnection;
    
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SUInstallerCommunicationProtocol)];
    newConnection.exportedObject = self;
    
    newConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SUInstallerCommunicationProtocol)];
    
    __weak AppInstaller *weakSelf = self;
    newConnection.interruptionHandler = ^{
        [weakSelf.activeConnection invalidate];
    };
    
    newConnection.invalidationHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            AppInstaller *strongSelf = weakSelf;
            if (strongSelf != nil) {
                if (strongSelf.activeConnection != nil && !strongSelf.willCompleteInstallation) {
                    SULog(@"Invalidation on remote port being called, and installation is not close enough to completion!");
                    [strongSelf cleanupAndExitWithStatus:EXIT_FAILURE];
                }
                strongSelf.communicator = nil;
                strongSelf.activeConnection = nil;
            }
        });
    };
    
    [newConnection resume];
    
    self.communicator = newConnection.remoteObjectProxy;
    
    return YES;
}

- (void)start
{
    [self.xpcListener resume];
    [self.agentConnection startListener];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FIRST_UPDATER_MESSAGE_TIMEOUT * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.receivedInstallationData) {
            SULog(@"Timeout: installation data was never received");
            [self cleanupAndExitWithStatus:EXIT_FAILURE];
        }
        
        if (!self.agentConnection.connected) {
            SULog(@"Timeout: agent connection was never initiated");
            [self cleanupAndExitWithStatus:EXIT_FAILURE];
        }
    });
}

/**
 * If the update is a package, then the download must be signed using DSA. No other verification is done.
 *
 * If the update is a bundle, then the download must also be signed using DSA.
 * However, a change of DSA public keys is allowed if the Apple Code Signing identities match and are valid.
 * Likewise, a change of Apple Code Signing identities is allowed if the DSA public keys match and the update is valid.
 *
 */
- (BOOL)validateUpdateForHost:(SUHost *)host downloadedToPath:(NSString *)downloadedPath extractedToPath:(NSString *)extractedPath DSASignature:(NSString *)DSASignature
{
    BOOL isPackage = NO;
    NSString *installSourcePath = [SUInstaller installSourcePathInUpdateFolder:extractedPath forHost:host isPackage:&isPackage isGuided:NULL];
    if (installSourcePath == nil) {
        SULog(@"No suitable install is found in the update. The update will be rejected.");
        return NO;
    }
    
    NSString *publicDSAKey = host.publicDSAKey;
    
    // Modern packages are not distributed as bundles and are code signed differently than regular applications
    if (isPackage) {
        if (nil == publicDSAKey) {
            SULog(@"The existing app bundle does not have a DSA key, so it can't verify installer packages.");
        }
        
        BOOL packageValidated = [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:publicDSAKey];
        
        if (!packageValidated) {
            SULog(@"DSA signature validation of the package failed. The update contains an installer package, and valid DSA signatures are mandatory for all installer packages. The update will be rejected. Sign the installer with a valid DSA key or use an .app bundle update instead.");
        }
        
        return packageValidated;
    }
    
    NSBundle *newBundle = [NSBundle bundleWithPath:installSourcePath];
    if (newBundle == nil) {
        SULog(@"No suitable bundle is found in the update. The update will be rejected.");
        return NO;
    }
    
    SUHost *newHost = [[SUHost alloc] initWithBundle:newBundle];
    NSString *newPublicDSAKey = newHost.publicDSAKey;
    
    if (newPublicDSAKey == nil) {
        SULog(@"No public DSA key is found in the update. For security reasons, the update will be rejected.");
        return NO;
    }
    
    BOOL dsaKeysMatch = (publicDSAKey == nil) ? NO : [publicDSAKey isEqualToString:newPublicDSAKey];

    // If the new DSA key differs from the old, then this check is not a security measure, because the new key is not trusted.
    // In that case, the check ensures that the app author has correctly used DSA keys, so that the app will be updateable in the next version.
    // However if the new and old DSA keys are the same, then this is a security measure.
    if (![SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:newPublicDSAKey]) {
        SULog(@"DSA signature validation failed. The update has a public DSA key and is signed with a DSA key, but the %@ doesn't match the signature. The update will be rejected.",
              dsaKeysMatch ? @"public key" : @"new public key shipped with the update");
        return NO;
    }
    
    BOOL updateIsCodeSigned = [SUCodeSigningVerifier bundleAtPathIsCodeSigned:installSourcePath];
    
    if (dsaKeysMatch) {
        NSError *error = nil;
        if (updateIsCodeSigned && ![SUCodeSigningVerifier codeSignatureIsValidAtPath:installSourcePath error:&error]) {
            SULog(@"The update archive has a valid DSA signature, but the app is also signed with Code Signing, which is corrupted: %@. The update will be rejected.", error);
            return NO;
        }
    } else {
        NSString *hostBundlePath = host.bundlePath;
        BOOL hostIsCodeSigned = [SUCodeSigningVerifier bundleAtPathIsCodeSigned:hostBundlePath];
        
        NSString *dsaStatus = newPublicDSAKey ? @"has a new DSA key that doesn't match the previous one" : (publicDSAKey ? @"removes the DSA key" : @"isn't signed with a DSA key");
        if (!hostIsCodeSigned || !updateIsCodeSigned) {
            NSString *acsStatus = !hostIsCodeSigned ? @"old app hasn't been signed with app Code Signing" : @"new app isn't signed with app Code Signing";
            SULog(@"The update archive %@, and the %@. At least one method of signature verification must be valid. The update will be rejected.", dsaStatus, acsStatus);
            return NO;
        }
        
        NSError *error = nil;
        if (![SUCodeSigningVerifier codeSignatureAtPath:hostBundlePath matchesSignatureAtPath:installSourcePath error:&error]) {
            SULog(@"The update archive %@, and the app is signed with a new Code Signing identity that doesn't match code signing of the original app: %@. At least one method of signature verification must be valid. The update will be rejected.", dsaStatus, error);
            return NO;
        }
    }
    
    return YES;
}

- (void)extractAndInstallUpdate
{
    [self.communicator handleMessageWithIdentifier:SUExtractionStarted data:[NSData data]];
    
    NSString *downloadPath = [self.installationData.updateDirectoryPath stringByAppendingPathComponent:self.installationData.downloadName];
    id <SUUnarchiverProtocol> unarchiver = [SUUnarchiver unarchiverForPath:downloadPath updatingHostBundlePath:self.host.bundlePath decryptionPassword:self.installationData.decryptionPassword delegate:self];
    if (!unarchiver) {
        SULog(@"Error: No valid unarchiver for %@!", downloadPath);
        [self unarchiverDidFail];
    } else {
        [unarchiver start];
    }
}

- (void)unarchiverExtractedProgress:(double)progress
{
    if (sizeof(progress) == sizeof(uint64_t)) {
        uint64_t progressValue = CFSwapInt64HostToLittle(*(uint64_t *)&progress);
        NSData *data = [NSData dataWithBytes:&progressValue length:sizeof(progressValue)];
        
        [self.communicator handleMessageWithIdentifier:SUExtractedArchiveWithProgress data:data];
    }
}

- (void)unarchiverDidFail
{
    // Client could try update again with different inputs
    // Eg: one common case is if a delta update fails, client may want to fall back to regular update
    self.installationData = nil;
    
    [self.communicator handleMessageWithIdentifier:SUArchiveExtractionFailed data:[NSData data]];
}

- (void)unarchiverDidFinish
{
    [self.communicator handleMessageWithIdentifier:SUValidationStarted data:[NSData data]];
    
    NSString *downloadPath = [self.installationData.updateDirectoryPath stringByAppendingPathComponent:self.installationData.downloadName];
    BOOL validationSuccess = [self validateUpdateForHost:self.host downloadedToPath:downloadPath extractedToPath:self.installationData.updateDirectoryPath DSASignature:self.installationData.dsaSignature];
    
    if (!validationSuccess) {
        SULog(@"Error: update validation was a failure");
        [self cleanupAndExitWithStatus:EXIT_FAILURE];
    } else {
        [self.communicator handleMessageWithIdentifier:SUInstallationStartedStage1 data:[NSData data]];
        
        self.agentConnectionCounter++;
        if (self.agentConnectionCounter == 2) {
            [self retrieveProcessIdentifierAndStartInstallation];
        }
    }
}

- (void)agentConnectionDidInitiate
{
    self.agentConnectionCounter++;
    if (self.agentConnectionCounter == 2) {
        [self retrieveProcessIdentifierAndStartInstallation];
    }
}

- (void)agentConnectionDidInvalidate
{
    if (self.agentConnectionCounter < 2) {
        SULog(@"Error: Agent connection invalidated before installation began");
        [self cleanupAndExitWithStatus:EXIT_FAILURE];
    }
}

- (void)retrieveProcessIdentifierAndStartInstallation
{
    // We use the relaunch path for the bundle to listen for termination instead of the host path
    // For a plug-in this makes a big difference; we want to wait until the app hosting the plug-in terminates
    // Otherwise for an app, the relaunch path and host path should be identical
    
    [self.agentConnection.agent registerRelaunchBundlePath:self.installationData.relaunchPath reply:^(NSNumber * _Nullable processIdentifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.terminationListener = [[TerminationListener alloc] initWithProcessIdentifier:processIdentifier];
            [self startInstallation];
        });
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RETRIEVE_PROCESS_IDENTIFIER_TIMEOUT * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.terminationListener == nil) {
            SULog(@"Timeour error: failed to retreive process identifier from agent");
            [self cleanupAndExitWithStatus:EXIT_FAILURE];
        }
    });
}

- (void)handleMessageWithIdentifier:(int32_t)identifier data:(NSData *)data
{
    if (identifier == SUInstallationData && self.installationData == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Mark that we have received the installation data
            // Do not rely on self.installationData != nil because we may set it to nil again if an early stage fails (i.e, archive extraction)
            self.receivedInstallationData = YES;
            
            SUInstallationInputData *installationData = (SUInstallationInputData *)SUUnarchiveRootObjectSecurely(data, [SUInstallationInputData class]);
            if (installationData == nil) {
                SULog(@"Error: Failed to unarchive input installation data");
                [self cleanupAndExitWithStatus:EXIT_FAILURE];
            } else {
                SUInstallationInputData *nonNullInstallationData = installationData;
                NSBundle *hostBundle = [NSBundle bundleWithPath:nonNullInstallationData.hostBundlePath];
                SUHost *host = [[SUHost alloc] initWithBundle:hostBundle];
                
                NSString *bundleIdentifier = hostBundle.bundleIdentifier;
                if (bundleIdentifier == nil || ![bundleIdentifier isEqualToString:self.hostBundleIdentifier]) {
                    SULog(@"Error: Failed to match host bundle identifiers %@ and %@", self.hostBundleIdentifier, bundleIdentifier);
                    [self cleanupAndExitWithStatus:EXIT_FAILURE];
                } else {
                    // This will be important later
                    if (nonNullInstallationData.relaunchPath == nil) {
                        SULog(@"Error: Failed to obtain relaunch path from installation data");
                        [self cleanupAndExitWithStatus:EXIT_FAILURE];
                    } else {
                        self.host = host;
                        self.installationData = installationData;
                        
                        [self extractAndInstallUpdate];
                    }
                }
            }
        });
    } else if (identifier == SUSentUpdateAppcastItemData) {
        SUAppcastItem *updateItem = (SUAppcastItem *)SUUnarchiveRootObjectSecurely(data, [SUAppcastItem class]);
        if (updateItem != nil) {
            SUInstallationInfo *installationInfo = [[SUInstallationInfo alloc] initWithAppcastItem:updateItem canSilentlyInstall:[self.installer canInstallSilently]];
            
            NSData *archivedData = SUArchiveRootObjectSecurely(installationInfo);
            if (archivedData != nil) {
                [self.agentConnection.agent registerInstallationInfoData:archivedData];
            }
        }
    } else if (identifier == SUResumeInstallationToStage2 && data.length == sizeof(uint8_t) * 2) {
        uint8_t relaunch = *((const uint8_t *)data.bytes);
        uint8_t showsUI = *((const uint8_t *)data.bytes + 1);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only applicable to stage 2
            self.shouldShowUI = (BOOL)showsUI;
            
            // Allow handling if we should relaunch at any time
            self.shouldRelaunch = (BOOL)relaunch;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.performedStage1Installation) {
                    // Resume the installation if we aren't done with stage 2 yet, and remind the client we are prepared to relaunch
                    dispatch_async(self.installerQueue, ^{
                        [self performStage2InstallationIfNeeded];
                    });
                }
            });
        });
    } else if (identifier == SUUpdaterAlivePong) {
        self.receivedUpdaterPong = YES;
    }
}

- (void)startInstallation
{
    self.willCompleteInstallation = YES;
    
    self.installerQueue = dispatch_queue_create("org.sparkle-project.sparkle.installer", DISPATCH_QUEUE_SERIAL);
    
    dispatch_async(self.installerQueue, ^{
        NSError *installerError = nil;
        id <SUInstallerProtocol> installer = [SUInstaller installerForHost:self.host updateDirectory:self.installationData.updateDirectoryPath allowingInteraction:self.allowsInteraction versionComparator:[SUStandardVersionComparator standardVersionComparator] error:&installerError];
        
        if (installer == nil) {
            SULog(@"Error: Failed to create installer instance with error: %@", installerError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self cleanupAndExitWithStatus:EXIT_FAILURE];
            });
            return;
        }
        
        NSError *firstStageError = nil;
        if (![installer performFirstStage:&firstStageError]) {
            SULog(@"Error: Failed to start installer with error: %@", firstStageError);
            [self.installer cleanup];
            self.installer = nil;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self cleanupAndExitWithStatus:EXIT_FAILURE];
            });
            return;
        }
        
        uint8_t canPerformSilentInstall = (uint8_t)[installer canInstallSilently];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.installer = installer;
            
            uint8_t targetTerminated = (uint8_t)self.terminationListener.terminated;
            
            uint8_t sendInformation[] = {canPerformSilentInstall, targetTerminated};
            
            NSData *sendData = [NSData dataWithBytes:sendInformation length:sizeof(sendInformation)];
            
            [self.communicator handleMessageWithIdentifier:SUInstallationFinishedStage1 data:sendData];
            
            self.performedStage1Installation = YES;
            
            // Stage 2 can still be run before we finish installation
            // if the updater requests for it before the app is terminated
            [self finishInstallationAfterHostTermination];
        });
    });
}

- (void)performStage2InstallationIfNeeded
{
    if (self.performedStage2Installation) {
        return;
    }
    
    NSError *secondStageError = nil;
    BOOL performedSecondStage = [self.installer performSecondStageAllowingUI:self.shouldShowUI error:&secondStageError];
    
    if (performedSecondStage) {
        self.performedStage2Installation = YES;
    }
    
    void (^cleanupAndExit)(void) = ^{
        SULog(@"Error: Failed to resume installer on stage 2 with error: %@", secondStageError);
        [self.installer cleanup];
        self.installer = nil;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanupAndExitWithStatus:EXIT_FAILURE];
        });
    };
    
    // Let the other end know we cancelled so they can fail gracefully without disturbing the user
    BOOL installationCancelled = (!performedSecondStage && secondStageError.code == SUInstallationCancelledError);
    if (performedSecondStage || installationCancelled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            uint8_t cancelled = (uint8_t)installationCancelled;
            uint8_t targetTerminated = (uint8_t)self.terminationListener.terminated;
            
            uint8_t sendInfo[] = {cancelled, targetTerminated};
            
            NSData *sendData = [NSData dataWithBytes:sendInfo length:sizeof(sendInfo)];
            [self.communicator handleMessageWithIdentifier:SUInstallationFinishedStage2 data:sendData];
            
            if (installationCancelled) {
                cleanupAndExit();
            }
        });
    }
    
    if (!performedSecondStage && !installationCancelled) {
        cleanupAndExit();
    }
}

- (void)finishInstallationAfterHostTermination
{
    [self.terminationListener startListeningWithCompletion:^(BOOL success) {
        if (!success) {
            SULog(@"Failed to listen for application termination");
            [self cleanupAndExitWithStatus:EXIT_FAILURE];
            return;
        }
        
        // Ask the updater if it is still alive
        // If they are, we will receive a pong response back
        // Reset if we received a pong just to be on the safe side
        self.receivedUpdaterPong = NO;
        [self.communicator handleMessageWithIdentifier:SUUpdaterAlivePing data:[NSData data]];
        
        // Launch our installer progress UI tool if only after a certain amount of time passes
        __block BOOL shouldLaunchInstallerProgress = YES;
        if (self.shouldShowUI && ![self.installer displaysUserProgress]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUDisplayProgressTimeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Make sure we're still eligible for showing the installer progress
                // Also if the updater process is still alive, showing the progress should not be our duty
                // if the communicator object is nil, the updater definitely isn't alive. However, if it is not nil,
                // this does not necessarily mean the updater is alive, so we should also check if we got a recent response back from the updater
                if (shouldLaunchInstallerProgress && (!self.receivedUpdaterPong || self.communicator == nil)) {
                    [self.agentConnection.agent showProgress];
                }
            });
        }
        
        dispatch_async(self.installerQueue, ^{
            [self performStage2InstallationIfNeeded];
            
            if (!self.performedStage2Installation) {
                // We failed and we're going to exit shortly
                return;
            }
            
            NSError *thirdStageError = nil;
            if (![self.installer performThirdStage:&thirdStageError]) {
                SULog(@"Failed to finalize installation with error: %@", thirdStageError);
                
                [self.installer cleanup];
                self.installer = nil;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self cleanupAndExitWithStatus:EXIT_FAILURE];
                });
                return;
            }
            
            self.performedStage3Installation = YES;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Make sure to terminate our displayed progress before we move onto cleanup & relaunch
                // This will also stop the agent from broadcasting the status info service, which we want to do before
                // we relaunch the app because the relaunched app could check the service upon launch..
                [self.agentConnection.agent stopProgress];
                shouldLaunchInstallerProgress = NO;
                
                [self.communicator handleMessageWithIdentifier:SUInstallationFinishedStage3 data:[NSData data]];
                
                NSString *installationPath = [SUInstaller installationPathForHost:self.host];
                
                if (self.shouldRelaunch) {
                    NSString *pathToRelaunch = nil;
                    // If the installation path differs from the host path, we give higher precedence for it than
                    // if the desired relaunch path differs from the host path
                    if (![installationPath.pathComponents isEqualToArray:self.host.bundlePath.pathComponents] || [self.installationData.relaunchPath.pathComponents isEqualToArray:self.host.bundlePath.pathComponents]) {
                        pathToRelaunch = installationPath;
                    } else {
                        pathToRelaunch = self.installationData.relaunchPath;
                    }
                    
                    [self.agentConnection.agent relaunchPath:pathToRelaunch];
                }
                
                dispatch_async(self.installerQueue, ^{
                    [self.installer cleanup];
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUTerminationTimeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self cleanupAndExitWithStatus:EXIT_SUCCESS];
                    });
                });
            });
        });
    }];
}

- (void)cleanupAndExitWithStatus:(int)status __attribute__((noreturn))
{
    // It's nice to tell the other end we're invalidating
    
    [self.activeConnection invalidate];
    self.activeConnection = nil;
    
    [self.xpcListener invalidate];
    self.xpcListener = nil;
    
    [self.agentConnection invalidate];
    self.agentConnection = nil;
    
    NSError *theError = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:self.installationData.updateDirectoryPath error:&theError]) {
        SULog(@"Couldn't remove update folder: %@.", theError);
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:[[NSBundle mainBundle] bundlePath] error:NULL];
    
    exit(status);
}

@end
