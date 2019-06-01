//
//  AppDelegate.m
//  Spotify Notifications
//

#import <ScriptingBridge/ScriptingBridge.h>
#import "Spotify.h"
#import "AppDelegate.h"
#import "SharedKeys.h"
#import "LaunchAtLogin.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    
    //Register default preferences values
    [NSUserDefaults.standardUserDefaults registerDefaults:[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UserDefaults" ofType:@"plist"]]];
    
    spotify =  [SBApplication applicationWithBundleIdentifier:SpotifyBundleID];
    
    accessToken = @"";

    [NSUserNotificationCenter.defaultUserNotificationCenter setDelegate:self];
    
    //Observe Spotify player state changes
    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(spotifyPlaybackStateChanged:)
                                                            name:SpotifyNotificationName
                                                          object:nil
                                              suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    [self setIcon];
    [self setupGlobalShortcutForNotifications];
    
    //User notification content images on 10.9+
    userNotificationContentImagePropertyAvailable = (NSAppKitVersionNumber >= NSAppKitVersionNumber10_9);
    if (!userNotificationContentImagePropertyAvailable) _albumArtToggle.enabled = NO;
    
    [LaunchAtLogin setAppIsLoginItem:[NSUserDefaults.standardUserDefaults boolForKey:kLaunchAtLoginKey]];
    
    //Check in case user opened application but Spotify already playing
    if (spotify.isRunning && spotify.playerState == SpotifyEPlSPlaying) {
        currentTrack = spotify.currentTrack;
        
        NSUserNotification *notification = [self userNotificationForCurrentTrack];
        [self deliverUserNotification:notification Force:YES];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupGlobalShortcutForNotifications {

    static NSString *const kPreferenceGlobalShortcut = @"ShowCurrentTrack";
    _shortcutView.associatedUserDefaultsKey = kPreferenceGlobalShortcut;
    
    [MASShortcutBinder.sharedBinder
     bindShortcutWithDefaultsKey:kPreferenceGlobalShortcut
     toAction:^{
         
         NSUserNotification *notification = [self userNotificationForCurrentTrack];
         
         if (currentTrack.name.length == 0) {
             
             notification.title = @"No Song Playing";
             
             if ([NSUserDefaults.standardUserDefaults boolForKey:kNotificationSoundKey])
                 notification.soundName = @"Pop";
         }
         
         [self deliverUserNotification:notification Force:YES];
     }];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    // Allow opening preferences by re-opening the app
    // This allows accessing preferences even when the status item is hidden
    if (!flag) [self showPreferences:nil];
    return YES;
}

- (IBAction)openSpotify:(NSMenuItem*)sender {
    [spotify activate];
}

- (IBAction)showLastFM:(NSMenuItem*)sender {
    
    //Artist - we always need at least this
    NSMutableString *urlText = [NSMutableString new];
    [urlText appendFormat:@"http://last.fm/music/%@/", currentTrack.artist];
    
    if (sender.tag >= 1) [urlText appendFormat:@"%@/", currentTrack.album];
    if (sender.tag == 2) [urlText appendFormat:@"%@/", currentTrack.name];
    
    NSString *url = [urlText stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification {
    return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {
    
    NSUserNotificationActivationType actionType = notification.activationType;
    
    if (actionType == NSUserNotificationActivationTypeContentsClicked) {
        [spotify activate];
        
    } else if (actionType == NSUserNotificationActivationTypeActionButtonClicked && spotify.playerState == SpotifyEPlSPlaying) {
        [spotify nextTrack];
    }
}

- (NSImage*)albumArtForTrack:(SpotifyTrack*)track {
    if (track.id) {
        //Looks hacky, but appears to work
        NSString *artworkUrl = [track.artworkUrl stringByReplacingOccurrencesOfString:@"http:" withString:@"https:"];
        NSData *artD = [NSData dataWithContentsOfURL:[NSURL URLWithString:artworkUrl]];
        
        if (artD) return [[NSImage alloc] initWithData:artD];
    }
    
    return  nil;
}

- (NSString*)formatDuration:(NSNumber*)duration {
    int seconds = duration.intValue;
    int m = (seconds / 60) % 60;
    int s = seconds % 60;
    
    return [NSString stringWithFormat:@"%02u:%02u", m, s];
}

- (NSString*)formatFloatsWithPercentage:(NSNumber*)n {
    double nDouble = [n doubleValue] * 100;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.maximumFractionDigits = 2;
    formatter.roundingMode = NSNumberFormatterRoundUp;
    
    NSString *nFormatted = [formatter stringFromNumber:[NSNumber numberWithDouble:nDouble]];
    return [NSString stringWithFormat:@"%%%@", nFormatted];
}

- (NSString*)generateBasicAuthHeader {
    NSString *auth = [NSString stringWithFormat:@"%@:%@", SpotifyClientId, SpotifySecretKey];
    NSData *nsdata = [auth dataUsingEncoding:NSUTF8StringEncoding];
    
    return [NSString stringWithFormat:@"%@ %@", @"Basic", [nsdata base64EncodedStringWithOptions:0]];
}

- (NSString*)generateBearerAuthHeader {
    return [NSString stringWithFormat:@"%@ %@", @"Bearer", accessToken];
}

- (NSString*)getAccessTokenFromSpotifyAPI {
    NSString *spotifyAccountsServiceURL = @"https://accounts.spotify.com/api/token";
    NSString *authHeader = [self generateBasicAuthHeader];
    NSString *post = @"grant_type=client_credentials";
    NSData *postData = [post dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
    NSString *postLength = [NSString stringWithFormat:@"%lu", (unsigned long)[postData length]];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    [request setURL:[NSURL URLWithString:spotifyAccountsServiceURL]];
    [request setHTTPMethod:@"POST"];
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
    [request setHTTPBody:postData];
    NSError *error;
    NSURLResponse *response;
    NSData *urlData=[NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSObject *res = [NSJSONSerialization JSONObjectWithData:urlData options:0 error:&error];
    
    return [res valueForKey:@"access_token"];
}

- (SpotifyTrackAudioFeatures*)getAudioFeaturesFromSpotifyAPI:(NSString*)trackId {
    // get an access token if it is empty
    if([accessToken length] == 0) accessToken = [self getAccessTokenFromSpotifyAPI];
    
    NSString *spotifyAPIURL = @"https://api.spotify.com/v1/audio-features";
    NSString *requestURL = [NSString stringWithFormat:@"%@/%@", spotifyAPIURL, trackId];
    NSString *authHeader = [self generateBearerAuthHeader];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    [request setURL:[NSURL URLWithString:requestURL]];
    [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
    NSError *error;
    NSURLResponse *response;
    NSData *urlData=[NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSObject *res = [NSJSONSerialization JSONObjectWithData:urlData options:0 error:&error];
    // handle token expiration
    if([[res valueForKey:@"error"] isEqualToString:@"invalid_client"]) {
        accessToken = [self getAccessTokenFromSpotifyAPI];
        [self getAudioFeaturesFromSpotifyAPI:trackId];
    }
    
    return (SpotifyTrackAudioFeatures*) res;
}

- (NSString*)formatInformativeTextWithAudioFeatures:(NSString*)artist :(SpotifyTrackAudioFeatures*)audioFeatures {
    NSDictionary *constants = @{
                                @"mode": @{
                                        @"0": @"Minor",
                                        @"1": @"Major"
                                        },
                                @"key": @{
                                        @"-1": @"Unknown",
                                        @"0": @"C",
                                        @"1": @"C♯/D♭",
                                        @"2": @"D",
                                        @"3": @"D♯/E♭",
                                        @"4": @"E",
                                        @"5": @"F",
                                        @"6": @"F♯/G♭",
                                        @"7": @"G",
                                        @"8": @"G♯/A♭",
                                        @"9": @"A",
                                        @"10": @"A♯/B♭",
                                        @"11": @"B"
                                        },
                                };
    NSString *key = [NSString stringWithFormat: @"%@", [audioFeatures valueForKey:@"key"]];
    NSString *mode = [NSString stringWithFormat: @"%@", [audioFeatures valueForKey:@"mode"]];
    NSString *text = [NSString stringWithFormat:
                      @"%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t%@: %@\t",
                      @"Artist", artist,
                      @"Duration", [self formatDuration:[audioFeatures valueForKey:@"duration_ms"]],
                      @"Tempo", [audioFeatures valueForKey:@"tempo"],
                      @"Key", [[constants valueForKey:@"key"] valueForKey:key],
                      @"Mode", [[constants valueForKey:@"mode"] valueForKey:mode],
                      @"Time Signature", [audioFeatures valueForKey:@"time_signature"],
                      @"Instrumentalness", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"instrumentalness"]],
                      @"Speechiness", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"speechiness"]],
                      @"Acousticness", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"acousticness"]],
                      @"Valence", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"valence"]],
                      @"Energy", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"energy"]],
                      @"Danceability", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"danceability"]],
                      @"Liveness", [self formatFloatsWithPercentage:[audioFeatures valueForKey:@"liveness"]],
                      @"Loudness", [audioFeatures valueForKey:@"loudness"]
                      ];
    return text;
}

- (NSUserNotification*)userNotificationForCurrentTrack {
    NSString *title = currentTrack.name;
    NSString *album = currentTrack.album;
    NSString *artist = currentTrack.artist;
    NSString *id = currentTrack.id;
    
    BOOL isAdvert = [currentTrack.spotifyUrl hasPrefix:@"spotify:ad"];
    
    // TODO: create a custom notification UI and show it instead of NSUserNotification
    NSUserNotification *notification = [NSUserNotification new];
    notification.title = (title.length > 0 && !isAdvert)? title : @"No Song Playing";
    if (album.length > 0 && !isAdvert) notification.subtitle = album;
    if (artist.length > 0 && !isAdvert) {
        SpotifyTrackAudioFeatures *audioFeatures = [self getAudioFeaturesFromSpotifyAPI:id];
        notification.informativeText = [self formatInformativeTextWithAudioFeatures:artist :audioFeatures];
    }
    
    BOOL includeAlbumArt = (userNotificationContentImagePropertyAvailable &&
                           [NSUserDefaults.standardUserDefaults boolForKey:kNotificationIncludeAlbumArtKey]
                            && !isAdvert);
    
    if (includeAlbumArt) notification.contentImage = [self albumArtForTrack:currentTrack];
    
    if (!isAdvert) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:kNotificationSoundKey])
            notification.soundName = @"Pop";
        
        notification.hasActionButton = YES;
        notification.actionButtonTitle = @"Skip";

        
        //Private APIs – remove if publishing to Mac App Store
        @try {
            //Force showing buttons even if "Banner" alert style is chosen by user
            [notification setValue:@YES forKey:@"_showsButtons"];
            
            //Show album art on the left side of the notification (where app icon normally is),
            //like iTunes does
            if (includeAlbumArt && notification.contentImage.isValid) {
                [notification setValue:notification.contentImage forKey:@"_identityImage"];
                notification.contentImage = nil;
            }
            
        } @catch (NSException *exception) {}
    }
    
    NSNumber *n = [NSNumber numberWithInt:2];
    [notification setValue:n forKey:@"_style"];
    return notification;
}

- (void)deliverUserNotification:(NSUserNotification*)notification Force:(BOOL)force {
    BOOL frontmost = [NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:SpotifyBundleID];
    
    if (frontmost && [NSUserDefaults.standardUserDefaults boolForKey:kDisableWhenSpotifyHasFocusKey]) return;
    
    BOOL deliver = force;
    
    //If notifications enabled, and current track isn't the same as the previous track
    if ([NSUserDefaults.standardUserDefaults boolForKey:kNotificationsKey] &&
        (![previousTrack.id isEqualToString:currentTrack.id] || [NSUserDefaults.standardUserDefaults boolForKey:kPlayPauseNotificationsKey])) {
        
        //If only showing notification for current song, remove all other notifications..
        if ([NSUserDefaults.standardUserDefaults boolForKey:kShowOnlyCurrentSongKey])
            [NSUserNotificationCenter.defaultUserNotificationCenter removeAllDeliveredNotifications];
        
        //..then deliver this one
        deliver = YES;
    }
    
    if (spotify.isRunning && deliver)
        [NSUserNotificationCenter.defaultUserNotificationCenter deliverNotification:notification];
}

- (void)notPlaying {
    _openSpotifyMenuItem.title = @"Open Spotify (Not Playing)";
    
    [NSUserNotificationCenter.defaultUserNotificationCenter removeAllDeliveredNotifications];
}

- (void)spotifyPlaybackStateChanged:(NSNotification*)notification {
    
    if ([notification.userInfo[@"Player State"] isEqualToString:@"Stopped"]) {
        [self notPlaying];
        return; //To stop us from checking accessing spotify (spotify.playerState below)..
        //..and then causing it to re-open
    }
    
    if (spotify.playerState == SpotifyEPlSPlaying) {
        
        _openSpotifyMenuItem.title = @"Open Spotify (Playing)";

        if (!_openLastFMMenu.isEnabled && [currentTrack.artist isNotEqualTo:NULL])
            [_openLastFMMenu setEnabled:YES];
        
        
        if (![previousTrack.id isEqualToString:currentTrack.id]) {
            previousTrack = currentTrack;
            currentTrack = spotify.currentTrack;
        }
        
        NSUserNotification *userNotification = [self userNotificationForCurrentTrack];
        [self deliverUserNotification:userNotification Force:NO];
        
        
    } else if ([NSUserDefaults.standardUserDefaults boolForKey:kShowOnlyCurrentSongKey]
               && (spotify.playerState == SpotifyEPlSPaused || spotify.playerState == SpotifyEPlSStopped)) {
        [self notPlaying];
    }

}

#pragma mark - Preferences

- (IBAction)showPreferences:(NSMenuItem*)sender {
    [_prefsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setIcon {
    
    NSInteger iconSelection = [NSUserDefaults.standardUserDefaults integerForKey:kIconSelectionKey];
    
    if (iconSelection == 2 && _statusBar) {
        _statusBar = nil;
        
    } else if (iconSelection == 0 || iconSelection == 1) {
        
        NSString *imageName = (iconSelection == 0)? @"status_bar_colour.tiff" : @"status_bar_black.tiff";
        if (!_statusBar) {
            _statusBar = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
            _statusBar.menu = _statusMenu;
            _statusBar.highlightMode = YES;
        }
        
        if (![_statusBar.image.name isEqualToString:imageName]) _statusBar.image = [NSImage imageNamed:imageName];
        
        _statusBar.image.template = (iconSelection == 1);
    }
}

- (IBAction)toggleIcons:(id)sender {
    [self setIcon];
}

- (IBAction)toggleStartup:(NSButton *)sender {
    
    BOOL launchAtLogin = sender.state;
    [NSUserDefaults.standardUserDefaults setBool:launchAtLogin forKey:kLaunchAtLoginKey];
    [LaunchAtLogin setAppIsLoginItem:launchAtLogin];
}

#pragma mark - Preferences Info Buttons

- (IBAction)showHome:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"http://spotify-notifications.citruspi.io"]];
}

- (IBAction)showSource:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/citruspi/Spotify-Notifications"]];
}

- (IBAction)showContributors:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/citruspi/Spotify-Notifications/graphs/contributors"]];
    
}

@end
