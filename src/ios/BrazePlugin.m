#import "BrazePlugin.h"

@import BrazeKit;
@import BrazeLocation;
@import BrazeUI;
@import UserNotifications;

// Stake custom: the plugin is the in-app message *presenter*, not a BrazeUI delegate. -presentMessage:
// is the single point BrazeKit hands a triggered message over, so every message passes through our
// code by protocol contract. BrazeInAppMessageUI is held privately and forwarded to for anything we
// do not render ourselves.
@interface BrazePlugin() <BrazeSDKAuthDelegate, BrazeInAppMessagePresenter>
  // Api
  @property NSString *APIKey;
  @property NSString *apiEndpoint;
  @property NSString *useAutomaticRequestPolicy;
  @property NSString *flushInterval;
  @property NSString *enableSDKAuth;

  // Push
  @property NSString *pushAppGroup;
  @property NSString *disableAutomaticPushHandling;
  @property NSString *disableAutomaticPushRegistration;
  @property NSString *disableUNAuthorizationOptionProvisional;
  @property NSString *displayForegroundPushNotifications;

  // Location
  @property NSString *enableLocationCollection;
  @property NSString *enableGeofences;

  // Logger
  @property NSString *logLevel;

  // General
  @property NSString *sessionTimeout;
  @property NSString *triggerActionMinimumTimeInterval;
  @property NSString *useUUIDAsDeviceId;
  @property NSString *forwardUniversalLinks;
  @property NSString *optInWhenPushAuthorized;
  @property NSString *enableIDFACollection;

  // Others
  @property NSString *sdkAuthCallbackID;

  // Stake custom: Braze's own in-app message UI, retained privately rather than registered as the
  // presenter. Everything we choose not to render ourselves is forwarded to it and draws exactly as
  // it did when Braze owned the presenter slot.
  @property BrazeInAppMessageUI *inAppMessageUI;

  // Stake custom: shared by -presentMessage: and getNextInApp(), so a message released from the hold
  // queue takes the identical path as one arriving after the latch opened.
  - (void)routeInAppMessage:(BRZInAppMessageRaw *)message;
  @property NSString *subscribeToInAppMessageCallbackID;
@end

static Braze *_braze;

@implementation BrazePlugin

bool isInAppMessageSubscribed;
bool useBrazeUIForInAppMessages;
// Stake custom: sticky latch, set by the first getNextInApp() and never cleared. Before it is set,
// every in-app message is held in heldInAppMessages so the app decides when the first one may appear;
// after it, messages present as they arrive, mid-session triggers included. This mirrors the pre-16
// plugin's `inAppDisplayAttempts >= 1` check — WHEN a message is shown must not change with this
// plugin, only WHO renders it.
bool hasRequestedInAppDisplay;
// Stake custom: messages that arrived before the latch opened, newest last to match Braze's own stack
// order. Held here rather than re-enqueued onto Braze's stack, because Braze drains its stack through
// -presentNext, which does not consult the presenter — a payload parked there could be drawn by Braze
// without ever meeting the claim test.
NSMutableArray<BRZInAppMessageRaw *> *heldInAppMessages;
// Stake custom: body marker identifying an in-app message this app renders itself. JS may override it
// on subscribe, but it is never cleared: without a marker nothing would be claimed and Braze would
// render our JSON body as HTML, painting the payload on screen. Defaulting it here keeps an app that
// has not been updated safe rather than broken.
NSString *stakeInAppMessageBodyMarker;
// Stake custom: retain-and-present, enabled by subscribeToInAppMessage(useBrazeUI = NO). Only messages
// this app renders itself are retained here by id and handed to JS; JS decides via
// showInAppMessage(id) / releaseInAppMessage(id). Everything else is forwarded to Braze's own UI.
// Nothing needs discarding: as the presenter, not forwarding a message is all it takes to own it.
NSMutableDictionary<NSNumber *, BRZInAppMessageRaw *> *pendingInAppMessages;
NSInteger nextInAppMessageId;

// Stake custom: most in-app messages retained for JS at once; the oldest are evicted beyond this.
static const NSUInteger kMaxPendingInAppMessages = 10;
// Stake custom: default claim marker. Version-agnostic on purpose ("V", not "V1"), so a new payload
// version needs no plugin release, and so this default cannot drift out of step with JS.
static NSString *const kDefaultStakeInAppMessageBodyMarker = @"stakeInAppMessageV";

+ (Braze *)braze {
  return _braze;
}

+ (void)setBraze:(Braze *)braze {
  _braze = braze;
}

- (void)pluginInitialize {
  NSDictionary *settings = self.commandDelegate.settings;

  // Api
  self.APIKey = settings[@"com.braze.ios_api_key"];
  if (self.APIKey == nil) {
    // Fallback to the deprecated API key setting
    self.APIKey = settings[@"com.braze.api_key"];
  }
  self.apiEndpoint = settings[@"com.braze.ios_api_endpoint"];
  self.useAutomaticRequestPolicy = settings[@"com.braze.ios_use_automatic_request_policy"];
  self.flushInterval = settings[@"com.braze.ios_flush_interval_seconds"];
  self.enableSDKAuth = settings[@"com.braze.sdk_authentication_enabled"];

  // Push
  self.pushAppGroup = settings[@"com.braze.ios_push_app_group"];
  self.disableAutomaticPushHandling = settings[@"com.braze.ios_disable_automatic_push_handling"];
  self.disableAutomaticPushRegistration = settings[@"com.braze.ios_disable_automatic_push_registration"];
  self.disableUNAuthorizationOptionProvisional = settings[@"com.braze.ios_disable_un_authorization_option_provisional"];
  self.displayForegroundPushNotifications = settings[@"com.braze.display_foreground_push_notifications"];

  // Location
  self.enableLocationCollection = settings[@"com.braze.enable_location_collection"];
  self.enableGeofences = settings[@"com.braze.geofences_enabled"];

  // Logger
  self.logLevel = settings[@"com.braze.ios_log_level"];

  // General
  self.sessionTimeout = settings[@"com.braze.ios_session_timeout"];
  self.triggerActionMinimumTimeInterval = settings[@"com.braze.trigger_action_minimum_time_interval_seconds"];
  self.useUUIDAsDeviceId = settings[@"com.braze.ios_use_uuid_as_device_id"];
  self.forwardUniversalLinks = settings[@"com.braze.ios_forward_universal_links"];
  self.optInWhenPushAuthorized = settings[@"com.braze.should_opt_in_when_push_authorized"];
  self.enableIDFACollection = settings[@"com.braze.ios_enable_idfa_automatic_collection"];

  isInAppMessageSubscribed = NO;
  useBrazeUIForInAppMessages = YES;
  // Stake custom: in-app messages are held until the first getNextInApp().
  hasRequestedInAppDisplay = NO;
  heldInAppMessages = [NSMutableArray array];
  // Stake custom: retain-and-present state.
  pendingInAppMessages = [NSMutableDictionary dictionary];
  nextInAppMessageId = 0;
  stakeInAppMessageBodyMarker = kDefaultStakeInAppMessageBodyMarker;

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didFinishLaunchingListener:) name:UIApplicationDidFinishLaunchingNotification object:nil];

  // Cordova iOS 8+ (Swift AppDelegate template) can load plugins after
  // UIApplicationDidFinishLaunchingNotification has already been delivered, so the observer
  // above would never fire. Run launch setup on the next main runloop pass if Braze is still unset.
  __weak BrazePlugin *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BrazePlugin *strongSelf = weakSelf;
    if (strongSelf == nil || [BrazePlugin braze] != nil) {
      return;
    }
    [strongSelf didFinishLaunchingListener:nil];
  });
}

- (void)didFinishLaunchingListener:(NSNotification *)notification {
  if ([BrazePlugin braze] != nil) {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidFinishLaunchingNotification object:nil];
    return;
  }

  BRZConfiguration *configuration = [[BRZConfiguration alloc] initWithApiKey:self.APIKey
                                                                    endpoint:self.apiEndpoint];

  // Set SDK Flavor
  [configuration.api setSdkFlavor:BRZSDKFlavorCordova];

  // Set the minimum logging level
  NSNumber *level = [[[NSNumberFormatter alloc] init] numberFromString:self.logLevel];
  NSInteger levelCast = [level integerValue];
  if (level && levelCast >= 0 && levelCast <= 3) {
    [configuration.logger setLevel:(BRZLoggerLevel)levelCast];
    NSLog(@"Log level set to: %hhu", (BRZLoggerLevel)levelCast);
  } else {
    NSLog(@"Log level value not valid. Setting value to: error (2).");
  }

  // ---- Push Notifications configuration

  // Set push automation from preferences
  if (![[self sanitizeString:self.disableAutomaticPushHandling] isEqualToString:@"yes"]) {
    // Enables all push automation
    configuration.push.automation = [[BRZConfigurationPushAutomation alloc] initEnablingAllAutomations:YES];
    // - Disable `willPresentNotification`, this is configured below from the
    //   `displayForegroundPushNotifications` setting
    configuration.push.automation.willPresentNotification = NO;
    // - Disable `requestAuthorizationAtLaunch`, this is configured below from the
    //   `disableAutomaticPushRegistration` setting
    configuration.push.automation.requestAuthorizationAtLaunch = NO;
    NSLog(@"Automatic push handling enabled.");
  } else {
    NSLog(@"Automatic push handling disabled.");
  }

  // Set display foreground push notifications
  if ([[self sanitizeString:self.displayForegroundPushNotifications] isEqualToString:@"yes"]) {
    configuration.push.automation.willPresentNotification = YES;
    NSLog(@"Foreground push notifications enabled.");
  } else {
    NSLog(@"Foreground push notifications disabled.");
  }

  // Set automatic request notification authorization
  if (![[self sanitizeString:self.disableAutomaticPushRegistration] isEqualToString:@"yes"]) {
    // Enable automatic push registration and device token registration
    configuration.push.automation.automaticSetup = YES;
    configuration.push.automation.registerDeviceToken = YES;
    // Enable request notification authorization
    configuration.push.automation.requestAuthorizationAtLaunch = YES;
    NSLog(@"Automatic push registration enabled.");
    // Set provisional notification authorization
    if (@available(iOS 12.0, *)) {
      if (![[self sanitizeString:self.disableUNAuthorizationOptionProvisional] isEqualToString:@"yes"]) {
        configuration.push.automation.authorizationOptions |= UNAuthorizationOptionProvisional;
        NSLog(@"Provisional push authorization enabled.");
      } else {
        NSLog(@"Provisional push authorization disabled.");
      }
    }
  } else {
    NSLog(@"Automatic push registration disabled.");
  }

  // Set location collection from preferences
  if ([[self sanitizeString:self.enableLocationCollection] isEqualToString:@"yes"]) {
    configuration.location.automaticLocationCollection = @YES;
    NSLog(@"Location collection enabled.");
  } else {
    NSLog(@"Location collection disabled.");
  }

  // Set geofences from preferences
  if ([[self sanitizeString:self.enableGeofences] isEqualToString:@"yes"]) {
    configuration.location.geofencesEnabled = @YES;
    NSLog(@"Geofences enabled.");
  } else {
    NSLog(@"Geofences disabled.");
  }

  // Set the minimum time interval between triggers (in seconds)
  NSNumber *interval = [[[NSNumberFormatter alloc] init] numberFromString:self.triggerActionMinimumTimeInterval];
  NSTimeInterval intervalCast = [interval doubleValue];
  if (interval && intervalCast >= 0) {
    [configuration setTriggerMinimumTimeInterval:intervalCast];
    NSLog(@"Minimum time interval between trigger actions set to: %f", intervalCast);
  } else {
    NSLog(@"Minimum time interval between trigger actions value not valid. Setting value to 30.");
  }

  // Sets if a randomly generated UUID should be used as the device ID
  if ([[self sanitizeString:self.useUUIDAsDeviceId] isEqualToString:@"yes"]) {
    configuration.useUUIDAsDeviceId = @YES;
    NSLog(@"Using UUID as Device ID enabled.");
  } else {
    NSLog(@"Using UUID as Device ID disabled.");
  }

  // Set if the SDK should automatically recognize and forward universal links to the system methods
  if ([[self sanitizeString:self.forwardUniversalLinks] isEqualToString:@"yes"]) {
    configuration.forwardUniversalLinks = @YES;
    NSLog(@"iOS universal link forwarding enabled.");
  } else {
    NSLog(@"iOS universal link forwarding disabled.");
  }

  // Set if a user’s notification subscription state should be set to optedIn when push permissions are authorized
  if ([[self sanitizeString:self.optInWhenPushAuthorized] isEqualToString:@"no"]) {
    configuration.optInWhenPushAuthorized = @NO;
    NSLog(@"User notification subscription state not automatically optedIn when push is authorized.");
  } else {
    NSLog(@"User notification subscription state automatically optedIn when push is authorized.");
  }

  // Set the time interval for session time out (in seconds)
  NSNumber *timeout = [[[NSNumberFormatter alloc] init] numberFromString:self.sessionTimeout];
  NSTimeInterval timeoutCast = [timeout doubleValue];
  if (timeout && timeoutCast >= 0) {
    [configuration setSessionTimeout:timeoutCast];
    NSLog(@"Session timeout interval set to: %f", timeoutCast);
  } else {
    NSLog(@"Session timeout interval value not valid. Setting value to 10.");
  }

  // Set SDK Metadata
  [configuration.api addSDKMetadata:@[[BRZSDKMetadata cordova]]];
  NSLog(@"SDK Metadata set.");

  // Set if request policy should be automatic or manual
  if ([[self sanitizeString: self.useAutomaticRequestPolicy] isEqualToString:@"no"]) {
    [configuration.api setRequestPolicy:BRZRequestPolicyManual];
    NSLog(@"Request policy set to: Manual.");
  } else {
    NSLog(@"Request policy set to: Automatic.");
  }

  // Set the interval in seconds between automatic data flushes
  NSNumber *flushInterval = [[[NSNumberFormatter alloc] init] numberFromString:self.flushInterval];
  NSTimeInterval flushIntervalCast = [flushInterval doubleValue];
  if (flushInterval && flushIntervalCast >= 0) {
    [configuration.api setFlushInterval:flushIntervalCast];
    NSLog(@"Flush interval set to: %f", flushIntervalCast);
  } else {
    NSLog(@"Flush interval value not valid. Setting value to 10.");
  }

  // Set the app group identifier for push stories.
  [configuration.push setAppGroup:self.pushAppGroup];
  NSLog(@"Push app group set to: %@.", self.pushAppGroup);

  // Initialize Braze with set configurations
  self.braze = [[Braze alloc] initWithConfiguration:configuration];
  self.subscriptions = [NSMutableArray array];
  [BrazePlugin setBraze:self.braze];
  NSLog(@"Braze initialized with set configurations.");

  // In-App Message UI
  // Stake custom: the plugin registers itself as the presenter and keeps Braze's UI privately.
  // BrazeKit calls -presentMessage: for every triggered message, so this is the one point every
  // message must pass through; the UI's own delegate is deliberately left unset, since anything we
  // forward has already been decided and should present immediately.
  //
  // Note `inAppMessagePresenter` is a strong reference, unlike `braze.delegate`, so Braze retains the
  // plugin. That is a cycle, and it is fine: the plugin lives for the lifetime of the app.
  self.inAppMessageUI = [[BrazeInAppMessageUI alloc] init];
  self.braze.inAppMessagePresenter = self;

  // Set the IDFA delegate for the plugin
  if ([[self sanitizeString:self.enableIDFACollection] isEqualToString:@"yes"]) {
    NSLog(@"IDFA collection enabled. Setting values for ad tracking.");
    [self.braze setIdentifierForAdvertiser:[self.idfaDelegate advertisingIdentifierString]];
    [self.braze setAdTrackingEnabled:[self.idfaDelegate isAdvertisingTrackingEnabledOrATTAuthorized]];
  } else {
    NSLog(@"IDFA collection disabled.");
  }

  // Set the SDK authentication delegate
  if ([[self sanitizeString:self.enableSDKAuth] isEqualToString:@"yes"]) {
    NSLog(@"SDK authentication enabled. To receive and handle authentication errors, call `subscribeToSdkAuthenticationFailures`.");
    self.braze.sdkAuthDelegate = self;
  } else {
    NSLog(@"SDK authentication disabled.");
  }

  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidFinishLaunchingNotification object:nil];
}

// MARK: - Braze
- (void)changeUser:(CDVInvokedUrlCommand *)command {
  NSString *userId = [command argumentAtIndex:0 withDefault:nil];
  NSString *sdkAuthSignature = [command argumentAtIndex:1 withDefault:nil];
  // Stake custom: retained messages belong to the outgoing user.
  [self clearPendingInAppMessages];
  if (userId && sdkAuthSignature) {
    [self.braze changeUser:userId sdkAuthSignature:sdkAuthSignature];
  } else if (userId) {
    [self.braze changeUser:userId];
  }
}

- (void)getUserId:(CDVInvokedUrlCommand *)command {
  NSString *userId = self.braze.user.identifier;
  if (!userId) {
    [self sendCordovaSuccessPluginResultAsNull:command];
  } else {
    [self sendCordovaSuccessPluginResultWithString:userId andCommand:command];
  }
}

- (void)setSdkAuthenticationSignature:(CDVInvokedUrlCommand *)command {
  NSString *sdkAuthSignature = [command argumentAtIndex:0 withDefault:nil];
  if (sdkAuthSignature) {
    [self.braze setSDKAuthenticationSignature:sdkAuthSignature];
  }
}

- (void)subscribeToSdkAuthenticationFailures:(CDVInvokedUrlCommand *)command {
  self.sdkAuthCallbackID = command.callbackId;
}

- (void)logCustomEvent:(CDVInvokedUrlCommand *)command {
  NSString *customEventName = [command argumentAtIndex:0 withDefault:nil];
  NSDictionary *properties = [command argumentAtIndex:1 withDefault:nil];
  [self.braze logCustomEvent:customEventName
                  properties:properties];
}

- (void)logPurchase:(CDVInvokedUrlCommand *)command {
  NSString *purchaseName = [command argumentAtIndex:0 withDefault:nil];
  NSString *currency = [command argumentAtIndex:2 withDefault:@"USD"];
  NSString *price = [[command argumentAtIndex:1 withDefault:nil] stringValue];
  NSUInteger quantity = [[command argumentAtIndex:3 withDefault:@1] integerValue];
  NSDictionary *properties = [command argumentAtIndex:4 withDefault:nil];
  [self.braze logPurchase:purchaseName
                 currency:currency
                    price:[[NSDecimalNumber decimalNumberWithString:price] doubleValue]
                 quantity:quantity
               properties:properties];
}

- (void)disableSdk:(CDVInvokedUrlCommand *)command {
  [self.braze setEnabled:NO];
}

- (void)enableSdk:(CDVInvokedUrlCommand *)command {
  [self.braze setEnabled:YES];
}

- (void)wipeData:(CDVInvokedUrlCommand *)command {
  [self.braze wipeData];
}

- (void)requestImmediateDataFlush:(CDVInvokedUrlCommand *)command {
  [self.braze requestImmediateDataFlush];
}

// MARK: - Braze.User
- (void)setFirstName:(CDVInvokedUrlCommand *)command {
  NSString *firstName = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setFirstName:firstName];
}

- (void)setLastName:(CDVInvokedUrlCommand *)command {
  NSString *lastName = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setLastName:lastName];
}

- (void)setEmail:(CDVInvokedUrlCommand *)command {
  NSString *email = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setEmail:email];
}

- (void)setGender:(CDVInvokedUrlCommand *)command {
  NSString *gender = [command argumentAtIndex:0 withDefault:nil];
  if ([gender.lowercaseString isEqualToString:@"f"]) {
    [self.braze.user setGender:BRZUserGender.female];
  } else if ([gender.lowercaseString isEqualToString:@"m"]) {
    [self.braze.user setGender:BRZUserGender.male];
  } else if ([gender.lowercaseString isEqualToString:@"n"]) {
    [self.braze.user setGender:BRZUserGender.notApplicable];
  } else if ([gender.lowercaseString isEqualToString:@"o"]) {
    [self.braze.user setGender:BRZUserGender.other];
  } else if ([gender.lowercaseString isEqualToString:@"p"]) {
    [self.braze.user setGender:BRZUserGender.preferNotToSay];
  } else if ([gender.lowercaseString isEqualToString:@"u"]) {
    [self.braze.user setGender:BRZUserGender.unknown];
  }
}

- (void)setDateOfBirth:(CDVInvokedUrlCommand *)command {
  NSInteger year = [[command argumentAtIndex:0 withDefault:@0] integerValue];
  NSInteger month = [[command argumentAtIndex:1 withDefault:@0] integerValue];
  NSInteger day = [[command argumentAtIndex:2 withDefault:@0] integerValue];

  if (month <= 12 && month > 0 && day <= 31 && day > 0) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [[NSDateComponents alloc] init];
    [components setDay:day];
    [components setMonth:month];
    [components setYear:year];
    NSDate *date = [calendar dateFromComponents:components];
    [self.braze.user setDateOfBirth:date];
  }
}

- (void)setCountry:(CDVInvokedUrlCommand *)command {
  NSString *country = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setCountry:country];
}

- (void)setHomeCity:(CDVInvokedUrlCommand *)command {
  NSString *homeCity = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setHomeCity:homeCity];
}

- (void)setPhoneNumber:(CDVInvokedUrlCommand *)command {
  NSString *phone = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setPhoneNumber:phone];
}

- (void)setLastKnownLocation:(CDVInvokedUrlCommand *)command {
  NSNumber *latitude = [command argumentAtIndex:0 withDefault:nil];
  NSNumber *longitude = [command argumentAtIndex:1 withDefault:nil];
  NSNumber *altitude = [command argumentAtIndex:2 withDefault:nil];
  NSNumber *horizontalAccuracy = [command argumentAtIndex:3 withDefault:nil];
  NSNumber *verticalAccuracy = [command argumentAtIndex:4 withDefault:nil];

  if (!latitude || !longitude || !horizontalAccuracy) {
    NSLog(@"Invalid location information with the latitude: %@, longitude: %@, horizontalAccuracy: %@",
          latitude ? latitude : @"nil",
          longitude ? longitude : @"nil",
          horizontalAccuracy ? horizontalAccuracy : @"nil");
  } else if (!verticalAccuracy || !altitude) {
    [self.braze.user setLastKnownLocationWithLatitude:[latitude doubleValue]
                                             longitude:[longitude doubleValue]
                                    horizontalAccuracy:[horizontalAccuracy doubleValue]];
  } else {
    [self.braze.user setLastKnownLocationWithLatitude:[latitude doubleValue]
                                            longitude:[longitude doubleValue]
                                             altitude:[altitude doubleValue]
                                   horizontalAccuracy:[horizontalAccuracy doubleValue]
                                     verticalAccuracy:[verticalAccuracy doubleValue]];
  }
}

- (void)setLocationCustomAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSNumber *latitude = [command argumentAtIndex:1 withDefault:nil];
  NSNumber *longitude = [command argumentAtIndex:2 withDefault:nil];

  if (!latitude || !longitude) {
    NSLog(@"Invalid location information with the latitude: %@, longitude: %@",
          latitude ? latitude : @"nil",
          longitude ? longitude : @"nil");
  } else {
    [self.braze.user setLocationCustomAttributeWithKey:key
                                              latitude:[latitude doubleValue]
                                             longitude:[longitude doubleValue]];
    NSLog(@"Location custom attribute set with key: %@, latitude: %@, longitude: %@", key, latitude, longitude);
  }
}

- (void)setPushNotificationSubscriptionType:(CDVInvokedUrlCommand *)command {
  NSString *subscriptionState = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setPushNotificationSubscriptionState:[self getSubscriptionStateFromString:subscriptionState]];
}

- (void)setEmailNotificationSubscriptionType:(CDVInvokedUrlCommand *)command {
  NSString *subscriptionState = [command argumentAtIndex:0 withDefault:nil];
  [self.braze.user setEmailSubscriptionState:[self getSubscriptionStateFromString:subscriptionState]];
}

- (void)setUserAttributionData:(CDVInvokedUrlCommand *)command {
  BRZUserAttributionData *attributionData = [[BRZUserAttributionData alloc]
                                             initWithNetwork:[command argumentAtIndex:0 withDefault:nil]
                                             campaign:[command argumentAtIndex:1 withDefault:nil]
                                             adGroup:[command argumentAtIndex:2 withDefault:nil]
                                             creative:[command argumentAtIndex:3 withDefault:nil]];
  [self.braze.user setAttributionData:attributionData];
}

- (BRZUserSubscriptionState)getSubscriptionStateFromString:(NSString *)stateString {
  if ([stateString.lowercaseString isEqualToString:@"opted_in"]) {
    return BRZUserSubscriptionStateOptedIn;
  } else if ([stateString.lowercaseString isEqualToString:@"unsubscribed"]) {
    return BRZUserSubscriptionStateUnsubscribed;
  } else {
    return BRZUserSubscriptionStateSubscribed;
  }
}

- (void)setBoolCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user setCustomAttributeWithKey:key boolValue:[value boolValue]];
  }
}

- (void)setStringCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user setCustomAttributeWithKey:key stringValue:value];
  }
}

- (void)setDoubleCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user setCustomAttributeWithKey:key doubleValue:[value doubleValue]];
  }
}

- (void)setDateCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[value longLongValue]];
    [self.braze.user setCustomAttributeWithKey:key dateValue:date];
  }
}

- (void)setIntCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user setCustomAttributeWithKey:key intValue:[value integerValue]];
  }
}

- (void)setCustomUserAttributeArray:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  id value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil && [value isKindOfClass:[NSArray class]]) {
    for (id item in value) {
      if (![item isKindOfClass:[NSString class]]) {
        NSLog(@"Custom attribute array contains element that is not of type string. Aborting.");
        return;
      }
    }
    [self.braze.user setCustomAttributeArrayWithKey:key array:value];
  }
}

- (void)setCustomUserAttributeObjectArray:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  id value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil && [value isKindOfClass:[NSArray class]]) {
    for (id item in value) {
      if (![item isKindOfClass:[NSDictionary class]]) {
        NSLog(@"Custom attribute array contains element that is not of type object. Aborting.");
        return;
      }
    }
    [self.braze.user setNestedCustomAttributeArrayWithKey:key value:value];
  }
}

- (void)setCustomUserAttributeObject:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  id value = [command argumentAtIndex:1 withDefault:nil];
  id merge = [command argumentAtIndex:2 withDefault:nil];

  if (key == nil || value == nil || ![value isKindOfClass:[NSDictionary class]]) {
    return;
  }

  if (!merge) {
    [self.braze.user setNestedCustomAttributeDictionaryWithKey:key value:value];
  } else if ([merge isKindOfClass:[NSNumber class]]) {
    BOOL mergeAsBool = [merge boolValue];
    [self.braze.user setNestedCustomAttributeDictionaryWithKey:key value:value merge:mergeAsBool];
  } else {
    NSLog(@"Invalid value received for `merge` parameter. Aborting.");
    return;
  }
}

- (void)unsetCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  if (key != nil) {
    [self.braze.user unsetCustomAttributeWithKey:key];
  }
}

- (void)incrementCustomUserAttribute:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *incrementValue = [command argumentAtIndex:1 withDefault:@1];
  if (key != nil) {
    [self.braze.user incrementCustomUserAttribute:key by:[incrementValue integerValue]];
  }
}

- (void)addToCustomAttributeArray:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user addToCustomAttributeStringArrayWithKey:key value:value];
  }
}

- (void)removeFromCustomAttributeArray:(CDVInvokedUrlCommand *)command {
  NSString *key = [command argumentAtIndex:0 withDefault:nil];
  NSString *value = [command argumentAtIndex:1 withDefault:nil];
  if (key != nil && value != nil) {
    [self.braze.user removeFromCustomAttributeStringArrayWithKey:key value:value];
  }
}

- (void)addAlias:(CDVInvokedUrlCommand *)command {
  NSString *aliasName = [command argumentAtIndex:0 withDefault:nil];
  NSString *aliasLabel = [command argumentAtIndex:1 withDefault:nil];
  if (aliasName != nil && aliasLabel != nil) {
    [self.braze.user addAlias:aliasName label:aliasLabel];
  }
}

- (void)setLanguage:(CDVInvokedUrlCommand *)command {
  NSString *language = [command argumentAtIndex:0 withDefault:nil];
  if (language != nil) {
    [self.braze.user setLanguage:language];
  }
}

- (void)addToSubscriptionGroup:(CDVInvokedUrlCommand *)command {
  NSString *groupId = [command argumentAtIndex:0 withDefault:nil];
  if (groupId != nil) {
    [self.braze.user addToSubscriptionGroupWithGroupId:groupId];
  }
}

- (void)removeFromSubscriptionGroup:(CDVInvokedUrlCommand *)command {
  NSString *groupId = [command argumentAtIndex:0 withDefault:nil];
  if (groupId != nil) {
    [self.braze.user removeFromSubscriptionGroupWithGroupId:groupId];
  }
}

- (void)getDeviceId:(CDVInvokedUrlCommand *)command {
  NSString *deviceId = self.braze.deviceId;
  [self sendCordovaSuccessPluginResultWithString:deviceId andCommand:command];
}

- (void)updateTrackingPropertyAllowList:(CDVInvokedUrlCommand *)command {
  NSDictionary* allowList = [command argumentAtIndex:0];
  NSArray<NSString *> *adding = allowList[@"adding"];
  NSArray<NSString *> *removing = allowList[@"removing"];
  NSArray<NSString *> *addingCustomEvents = allowList[@"addingCustomEvents"];
  NSArray<NSString *> *removingCustomEvents = allowList[@"removingCustomEvents"];
  NSArray<NSString *> *addingCustomAttributes = allowList[@"addingCustomAttributes"];
  NSArray<NSString *> *removingCustomAttributes = allowList[@"removingCustomAttributes"];

  NSMutableSet<BRZTrackingProperty *> *addingSet = [NSMutableSet set];
  NSMutableSet<BRZTrackingProperty *> *removingSet = [NSMutableSet set];

  for (NSString *propertyString in adding) {
    [addingSet addObject:[self convertTrackingProperty:(propertyString)]];
  }

  for (NSString *propertyString in removing) {
    [removingSet addObject:[self convertTrackingProperty:(propertyString)]];
  }

  // Parse custom strings
  if (addingCustomEvents.count > 0) {
    NSSet<NSString *> *customEvents = [NSSet setWithArray:addingCustomEvents];
    [addingSet addObject:[BRZTrackingProperty customEventWithEvents:customEvents]];
  }
  if (removingCustomEvents.count > 0) {
    NSSet<NSString *> *customEvents = [NSSet setWithArray:removingCustomEvents];
    [removingSet addObject:[BRZTrackingProperty customAttributeWithAttributes:customEvents]];
  }
  if (addingCustomAttributes.count > 0) {
    NSSet<NSString *> *customAttributes = [NSSet setWithArray:addingCustomAttributes];
    [addingSet addObject:[BRZTrackingProperty customAttributeWithAttributes:customAttributes]];
  }
  if (removingCustomAttributes.count > 0) {
    NSSet<NSString *> *customAttributes = [NSSet setWithArray:removingCustomAttributes];
    [removingSet addObject:[BRZTrackingProperty customAttributeWithAttributes:customAttributes]];
  }

  NSLog(@"Updating tracking allow list by adding: %@, removing %@", addingSet, removingSet);
  [self.braze updateTrackingAllowListAdding:addingSet removing:removingSet];
}

- (void)setAdTrackingEnabled:(CDVInvokedUrlCommand *)command {
  id argument = [command argumentAtIndex:0 withDefault:nil];

  if (argument == nil) {
    NSLog(@"Error: No argument provided for setAdTrackingEnabled.");
    return;
  }

  if (![argument isKindOfClass:[NSNumber class]]) {
    NSLog(@"Error: Expected argument to be a boolean value for setAdTrackingEnabled.");
    return;
  }

  BOOL adTrackingEnabled = [argument boolValue];

  if (adTrackingEnabled) {
    [self.braze setAdTrackingEnabled:YES];
    NSLog(@"Ad tracking enabled.");
  } else {
    [self.braze setAdTrackingEnabled:NO];
    NSLog(@"Ad tracking disabled.");
  }
}

// MARK: - BrazeUI
- (void)launchContentCards:(CDVInvokedUrlCommand *)command {
  [self.braze.contentCards requestRefresh];

  BRZContentCardUIModalViewController *contentCardsModal = [[BRZContentCardUIModalViewController alloc] initWithBraze:self.braze];
  UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
  UIViewController *mainViewController = keyWindow.rootViewController;
  [mainViewController presentViewController:contentCardsModal animated:YES completion:nil];
}

// MARK: - Content Cards
- (void)requestContentCardsRefresh:(CDVInvokedUrlCommand *)command {
  [self.braze.contentCards requestRefresh];
}

- (void)logContentCardClicked:(CDVInvokedUrlCommand *)command {
  NSString *idString = [command argumentAtIndex:0 withDefault:nil];
  BRZContentCardRaw *cardToClick = [self getContentCardById:idString];
  if (cardToClick) {
    [cardToClick logClickUsing:self.braze];
  }
}

- (void)logContentCardDismissed:(CDVInvokedUrlCommand *)command {
  NSString *idString = [command argumentAtIndex:0 withDefault:nil];
  BRZContentCardRaw *cardToDismiss = [self getContentCardById:idString];
  if (cardToDismiss) {
    [cardToDismiss logDismissedUsing:self.braze];
  }
}

- (void)logContentCardImpression:(CDVInvokedUrlCommand *)command {
  NSString *idString = [command argumentAtIndex:0 withDefault:nil];
  BRZContentCardRaw *cardToView = [self getContentCardById:idString];
  if (cardToView) {
    [cardToView logImpressionUsing:self.braze];
  }
}

- (void)getContentCardsFromServer:(CDVInvokedUrlCommand *)command {
  [self.braze.contentCards requestRefreshWithCompletion:^(NSArray<BRZContentCardRaw *> * _Nullable cards, NSError * _Nullable error) {
    if (error) {
      NSLog(@"%@", error.debugDescription);
      [self sendCordovaErrorPluginResultWithString:error.debugDescription andCommand:command];
    } else {
      NSLog(@"Got Content Cards from server callback");
      [self getContentCardsFromCache:command];
    }
  }];
}

- (void)getContentCardsFromCache:(CDVInvokedUrlCommand *)command {
  NSArray<BRZContentCardRaw *> *cards = [self.braze.contentCards cards];

  NSMutableArray *mappedCards = [NSMutableArray arrayWithCapacity:[cards count]];
  [cards enumerateObjectsUsingBlock:^(id card, NSUInteger idx, BOOL *stop) {
     [mappedCards addObject:[BrazePlugin formattedContentCard:card]];
  }];

  [self sendCordovaSuccessPluginResultWithArray:mappedCards andCommand:command];
}

- (nullable BRZContentCardRaw *)getContentCardById:(NSString *)idString {
  NSArray<BRZContentCardRaw *> *cards = self.braze.contentCards.cards;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"identifier == %@", idString];
  NSArray *filteredArray = [cards filteredArrayUsingPredicate:predicate];

  if (filteredArray.count) {
    return filteredArray[0];
  }

  return nil;
}

+ (NSDictionary *)formattedContentCard:(BRZContentCardRaw *)card {
  NSMutableDictionary *formattedContentCardData = [NSMutableDictionary dictionary];

  formattedContentCardData[@"id"] = card.identifier;
  formattedContentCardData[@"created"] = @(card.createdAt);
  formattedContentCardData[@"expiresAt"] = @(card.expiresAt);
  formattedContentCardData[@"viewed"] = @(card.viewed);
  formattedContentCardData[@"clicked"] = @(card.clicked);
  formattedContentCardData[@"pinned"] = @(card.pinned);
  formattedContentCardData[@"dismissed"] = @(card.removed);
  formattedContentCardData[@"dismissible"] = @(card.dismissible);
  formattedContentCardData[@"url"] = [card.url absoluteString] ?: [NSNull null];
  formattedContentCardData[@"openURLInWebView"] = @(card.useWebView);
  formattedContentCardData[@"isTest"] = @(card.test);

  BOOL isControl = card.type == BRZContentCardRawTypeControl;
  formattedContentCardData[@"isControl"] = @(isControl);

  if (card.extras != nil) {
    formattedContentCardData[@"extras"] = [BrazePlugin getJsonFromExtras:card.extras];
  }

  switch (card.type) {
    case BRZContentCardRawTypeClassic:
      formattedContentCardData[@"image"] = [card.image absoluteString] ?: [NSNull null];
      formattedContentCardData[@"title"] = card.title;
      formattedContentCardData[@"cardDescription"] = card.cardDescription;
      formattedContentCardData[@"domain"] = card.domain ?: [NSNull null];
      formattedContentCardData[@"type"] = @"Classic";
      break;
    case BRZContentCardRawTypeImageOnly:
      formattedContentCardData[@"image"] = [card.image absoluteString];
      formattedContentCardData[@"imageAspectRatio"] = @(card.imageAspectRatio);
      formattedContentCardData[@"type"] = @"ImageOnly";
      break;
    case BRZContentCardRawTypeCaptionedImage:
      formattedContentCardData[@"image"] = [card.image absoluteString];
      formattedContentCardData[@"imageAspectRatio"] = @(card.imageAspectRatio);
      formattedContentCardData[@"title"] = card.title;
      formattedContentCardData[@"cardDescription"] = card.cardDescription;
      formattedContentCardData[@"domain"] = card.domain ?: [NSNull null];
      formattedContentCardData[@"type"] = @"Captioned";
      break;
    case BRZContentCardRawTypeControl:
      break;
  }

  return formattedContentCardData;
}

+ (NSString *)getJsonFromExtras:(NSDictionary *)extras {
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:extras
                                                     options:0
                                                       error:&error];

  if (!jsonData) {
    NSLog(@"Got an error in getJsonFromExtras: %@", error);
    return @"{}";
  } else {
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  }
}

// MARK: - In-App Messages

/// Subscribes to in-app message updates.
- (void)subscribeToInAppMessage:(CDVInvokedUrlCommand *)command {
  BOOL useBrazeUI = [[command argumentAtIndex:0 withDefault:@YES] boolValue];
  useBrazeUIForInAppMessages = useBrazeUI;
  isInAppMessageSubscribed = YES;

  // Stake custom: JS may override the marker identifying a message this app renders itself, so the
  // payload contract can move without a plugin release. An absent or empty value keeps the default —
  // clearing it would let Braze render our JSON body as HTML.
  id marker = [command argumentAtIndex:1 withDefault:nil];
  if ([marker isKindOfClass:[NSString class]] && [(NSString *)marker length] > 0) {
    stakeInAppMessageBodyMarker = (NSString *)marker;
  }

  // Stake custom: release a previous subscription's callback before replacing it. Overwriting it
  // alone would leave the old callback id pinned in Cordova's callback map for the life of the
  // page, never completed and never called again.
  NSString *previousCallbackID = self.subscribeToInAppMessageCallbackID;
  if (previousCallbackID != nil && ![previousCallbackID isEqualToString:command.callbackId]) {
    CDVPluginResult *release = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [release setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:release callbackId:previousCallbackID];
  }

  self.subscribeToInAppMessageCallbackID = command.callbackId;
}

#pragma mark - Stake custom

/// Prompts the user for push notification permission and informs Braze of the result.
- (void)promptForPush:(CDVInvokedUrlCommand *)command {
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  // If no delegate has been set yet, use the app delegate (matching Braze's automatic setup).
  if (center.delegate == nil) {
    center.delegate = (id<UNUserNotificationCenterDelegate>)[UIApplication sharedApplication].delegate;
  }
  UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
  [center requestAuthorizationWithOptions:options
                        completionHandler:^(BOOL granted, NSError *_Nullable error) {
                          NSLog(@"Push authorization completed. Granted: %d", granted);
                        }];
  [[UIApplication sharedApplication] registerForRemoteNotifications];

  NSString *packageName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"];
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:packageName];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/// Presents the next held in-app message, and marks the app ready to show them.
///
/// The readiness latch is deliberately sticky: the app is saying "I am ready to show in-app messages",
/// not "show me exactly one". Messages arriving later — including mid-session triggers — present as
/// they arrive rather than waiting for another call.
///
/// One message is released per call, matching -presentNext. Braze's own stack is drained too: nothing
/// of ours can be parked there, but BrazeUI stacks a message itself when another is already on screen.
- (void)getNextInApp:(CDVInvokedUrlCommand *)command {
  NSLog(@"Displaying next in-app message");
  hasRequestedInAppDisplay = YES;

  BRZInAppMessageRaw *held = [heldInAppMessages lastObject];
  if (held != nil) {
    [heldInAppMessages removeLastObject];
    [self routeInAppMessage:held];
  } else {
    [self.inAppMessageUI presentNext];
  }

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"OK"];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/// Returns the number of in-app messages awaiting display: ours held before the latch opened, those
/// retained for JS, and any Braze stacked itself behind a message already on screen.
- (void)inAppMessagesRemainingOnStack:(CDVInvokedUrlCommand *)command {
  int remaining = (int)heldInAppMessages.count
                  + (int)pendingInAppMessages.count
                  + (int)self.inAppMessageUI.stack.count;
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:remaining];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/// Hands a retained in-app message back to Braze so Braze renders it with its own UI.
///
/// Reachable whenever the native claim test over-claims: it matches the marker anywhere in the body,
/// while JS extracts the payload script before testing, so a Braze-authored message merely mentioning
/// the marker in its copy arrives here. It presents straight through the private UI, which cannot
/// re-enter our own gate, so no authorisation handshake is needed.
///
/// BrazeUI refuses to present a message whose context is invalid, so the context is rebuilt first.
- (void)showInAppMessage:(CDVInvokedUrlCommand *)command {
  BRZInAppMessageRaw *message = [self takePendingInAppMessage:[command argumentAtIndex:0 withDefault:nil]];
  if (message == nil) {
    NSLog(@"showInAppMessage: no retained in-app message for the given id");
    CDVPluginResult *error = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                              messageAsString:@"No retained in-app message for the given id"];
    [self.commandDelegate sendPluginResult:error callbackId:command.callbackId];
    return;
  }

  // Rebuild the context when it is missing or spent. A dead context is worse than none: BrazeUI waves
  // a context-less message through but rejects one whose context is invalid.
  if (message.context == nil || !message.context.valid) {
    message.context = [[BRZInAppMessageContext alloc] initWithMessageRaw:message using:self.braze];
  }

  [self.inAppMessageUI presentMessage:message];

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/// Stops retaining an in-app message JS has finished with (rendered itself, or dropped).
- (void)releaseInAppMessage:(CDVInvokedUrlCommand *)command {
  [self takePendingInAppMessage:[command argumentAtIndex:0 withDefault:nil]];
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

/// Retains `message` and returns the id JS refers to it by.
///
/// The oldest entries are evicted beyond `kMaxPendingInAppMessages` so a JS crash between delivery
/// and showInAppMessage/releaseInAppMessage cannot leak messages. Ids increase monotonically, so
/// the smallest key is always the oldest entry.
- (NSInteger)retainInAppMessage:(BRZInAppMessageRaw *)message {
  NSInteger messageId = nextInAppMessageId++;
  pendingInAppMessages[@(messageId)] = message;
  while (pendingInAppMessages.count > kMaxPendingInAppMessages) {
    NSArray<NSNumber *> *oldestFirst = [pendingInAppMessages.allKeys sortedArrayUsingSelector:@selector(compare:)];
    [pendingInAppMessages removeObjectForKey:oldestFirst.firstObject];
  }
  return messageId;
}

/// Removes and returns the retained in-app message for `messageId`, or nil when there is none.
///
/// `messageId` comes straight off `argumentAtIndex:`, so it is whatever JS passed. Anything that is not
/// a number is rejected rather than coerced: `[@"foo" integerValue]` is 0, and 0 is a real id — the
/// first one minted — so coercing would show or release someone else's message.
- (BRZInAppMessageRaw *)takePendingInAppMessage:(id)messageId {
  if (![messageId isKindOfClass:[NSNumber class]]) {
    return nil;
  }
  NSNumber *key = @([(NSNumber *)messageId integerValue]);
  BRZInAppMessageRaw *message = pendingInAppMessages[key];
  [pendingInAppMessages removeObjectForKey:key];
  return message;
}

/// Drops every in-app message this plugin is holding — both those awaiting the latch and those
/// retained for JS.
- (void)clearPendingInAppMessages {
  [heldInAppMessages removeAllObjects];
  [pendingInAppMessages removeAllObjects];
}

/// Whether `message` carries a body this app renders itself, so Braze must not draw it.
///
/// A version-agnostic substring test on the whole body. A Stake body is an inert HTML document with the
/// payload in a script block, so it does not start with `{` — there is no cheap structural prefix left
/// to test here, and a stricter test would let Braze draw the payload.
///
/// This deliberately errs toward over-claiming: JS applies the narrow test (extract the payload script,
/// then look for the marker inside it) and hands anything native wrongly claimed straight back with
/// showInAppMessage(id). Over-claiming costs a round trip; under-claiming paints a payload on screen.
///
/// Anything Braze authored — survey, NPS, drag-and-drop template, hand-written HTML — carries no marker
/// and is left entirely to Braze. A control message has no body and also fails, so Braze still logs its
/// enrolment and A/B lift is unaffected.
- (BOOL)isStakeRenderedInAppMessage:(BRZInAppMessageRaw *)message {
  NSString *body = message.message;
  if (body == nil) {
    return NO;
  }
  return [body containsString:stakeInAppMessageBodyMarker];
}

/// Hides the currently displayed in-app message.
- (void)hideCurrentInAppMessage:(CDVInvokedUrlCommand *)command {
  [self.inAppMessageUI dismiss];
}

/// Logs an in-app message impression.
- (void)logInAppMessageImpression:(CDVInvokedUrlCommand *)command {
  NSString *inAppMessageString  = [command argumentAtIndex:0 withDefault:nil];
  NSLog(@"logInAppMessageImpression called with value %@", inAppMessageString);
  BRZInAppMessageRaw *inAppMessage = [self getInAppMessageFromString:inAppMessageString];
  if (inAppMessage) {
    [inAppMessage logImpressionUsing:self.braze];
  } else {
    NSLog(@"logInAppMessageImpression could not parse inAppMessage. Not logging impression.");
  }
}

/// Logs when an in-app message was clicked.
- (void)logInAppMessageClicked:(CDVInvokedUrlCommand *)command {
  NSString *inAppMessageString  = [command argumentAtIndex:0 withDefault:nil];
  NSLog(@"logInAppMessageClicked called with value %@", inAppMessageString);
  BRZInAppMessageRaw *inAppMessage = [self getInAppMessageFromString:inAppMessageString];
  if (inAppMessage) {
    [inAppMessage logClickWithButtonId:nil using:self.braze];
  } else {
    NSLog(@"logInAppMessageClicked could not parse inAppMessage. Not logging click.");
  }
}

/// Logs when an in-app message button was clicked.
- (void)logInAppMessageButtonClicked:(CDVInvokedUrlCommand *)command {
  NSString *inAppMessageString  = [command argumentAtIndex:0 withDefault:nil];
  NSNumber *button = [command argumentAtIndex:1 withDefault:0];
  NSLog(@"logInAppMessageButtonClicked called with value %@, button: %@", inAppMessageString, button);
  BRZInAppMessageRaw *inAppMessage = [self getInAppMessageFromString:inAppMessageString];
  double buttonId = [button doubleValue];
  if (inAppMessage) {
    [inAppMessage logClickWithButtonId:[@(buttonId) stringValue] using:self.braze];
  } else {
    NSLog(@"logInAppMessageButtonClicked could not parse inAppMessage. Not logging button click.");
  }
}

/// Process and perform in-app message click actions.
- (void)performInAppMessageAction:(CDVInvokedUrlCommand *)command {
  NSString *inAppMessageString  = [command argumentAtIndex:0 withDefault:nil];
  NSNumber *button = [command argumentAtIndex:1 withDefault:0];
  NSLog(@"performInAppMessageAction called with value %@, and button %@", inAppMessageString, button);
  BRZInAppMessageRaw *inAppMessage = [self getInAppMessageFromString:inAppMessageString];

  double buttonId = [button doubleValue];

  if (inAppMessage) {
    NSURL* url = nil;
    BOOL useWebView = NO;
    BRZInAppMessageRawClickAction clickAction = BRZInAppMessageRawClickActionURL;

    if (buttonId < 0) {
      url = inAppMessage.url;
      useWebView = inAppMessage.useWebView;
      clickAction = inAppMessage.clickAction;
    } else {
      for(int i = 0; i < inAppMessage.buttons.count; i++) {
        if (inAppMessage.buttons[i].identifier == buttonId) {
          url = inAppMessage.buttons[i].url;
          useWebView = inAppMessage.buttons[i].useWebView;
          clickAction = inAppMessage.buttons[i].clickAction;
        }
      }
    }

    NSLog(@"performInAppMessageAction trying %@", inAppMessage.url);
    inAppMessage.context = [[BRZInAppMessageContext alloc] initWithMessageRaw:inAppMessage using:self.braze];
    [inAppMessage.context processClickAction:clickAction url:url useWebView:useWebView];
  } else {
    NSLog(@"performInAppMessageAction could not parse inAppMessage. Not performing action.");
  }
}

/// Returns the in-app message for the JSON string. If the JSON fails decoding, returns nil.
- (BRZInAppMessageRaw *)getInAppMessageFromString:(NSString *)inAppMessageJSONString {
  NSData *inAppMessageData = [inAppMessageJSONString dataUsingEncoding:NSUTF8StringEncoding];
  BRZInAppMessageRaw *message = [BRZInAppMessageRaw decodingWithJson:inAppMessageData];
  return message;
}

// MARK: - Feature Flags
- (void)getFeatureFlag:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (featureFlag == nil) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }
  NSError* error = nil;
  id flagJSON = [NSJSONSerialization JSONObjectWithData:[featureFlag json]
                                                options:NSJSONReadingMutableContainers
                                                  error:&error];
  if (error || flagJSON == nil) {
    [self sendCordovaErrorPluginResultWithString:error.debugDescription andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultWithDictionary:flagJSON andCommand:command];
  }
}

- (void)getAllFeatureFlags:(CDVInvokedUrlCommand *)command {
  [self sendCordovaSuccessPluginResultWithArray:[BrazePlugin formattedFeatureFlagsMap:self.braze.featureFlags.featureFlags]
                                     andCommand:command];
}

- (void)refreshFeatureFlags:(CDVInvokedUrlCommand *)command {
  [self.braze.featureFlags requestRefresh];
}

- (void)subscribeToFeatureFlagUpdates:(CDVInvokedUrlCommand *)command {
  [self.subscriptions addObject:[self.braze.featureFlags subscribeToUpdates:^(NSArray<BRZFeatureFlag *> * featureFlags) {
    NSArray<NSDictionary *> *mappedFlags = [BrazePlugin formattedFeatureFlagsMap:featureFlags];
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:mappedFlags];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }]];
}

- (void)getFeatureFlagBooleanProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSNumber *boolProperty = [featureFlag boolPropertyForKey:propertyKey];
  if (boolProperty) {
    [self sendCordovaSuccessPluginResultWithBool:boolProperty andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)getFeatureFlagStringProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSString *stringProperty = [featureFlag stringPropertyForKey:propertyKey];
  if (stringProperty) {
    [self sendCordovaSuccessPluginResultWithString:stringProperty andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)getFeatureFlagNumberProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSNumber *numberProperty = [featureFlag numberPropertyForKey:propertyKey];
  if (numberProperty) {
    [self sendCordovaSuccessPluginResultWithDouble:[numberProperty doubleValue] andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)getFeatureFlagTimestampProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSNumber *timestampProperty = [featureFlag timestampPropertyForKey:propertyKey];
  if (timestampProperty) {
    [self sendCordovaSuccessPluginResultWithDouble:[timestampProperty doubleValue] andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)getFeatureFlagJSONProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSDictionary *jsonProperty = [featureFlag jsonObjectPropertyForKey:propertyKey];
  if (jsonProperty) {
    [self sendCordovaSuccessPluginResultWithDictionary:jsonProperty andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)getFeatureFlagImageProperty:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  NSString *propertyKey = [command argumentAtIndex:1 withDefault:nil];

  BRZFeatureFlag *featureFlag = [self.braze.featureFlags featureFlagWithId:featureFlagId];
  if (!featureFlag) {
    [self sendCordovaSuccessPluginResultAsNull:command];
    return;
  }

  NSString *imageProperty = [featureFlag imagePropertyForKey:propertyKey];
  if (imageProperty) {
    [self sendCordovaSuccessPluginResultWithString:imageProperty andCommand:command];
  } else {
    [self sendCordovaSuccessPluginResultAsNull:command];
  }
}

- (void)logFeatureFlagImpression:(CDVInvokedUrlCommand *)command {
  NSString *featureFlagId = [command argumentAtIndex:0 withDefault:nil];
  if (featureFlagId) {
    [self.braze.featureFlags logFeatureFlagImpressionWithId:featureFlagId];
  } else {
    NSLog(@"No valid feature flag ID entered.");
  }
}

+ (NSArray<NSDictionary *> *)formattedFeatureFlagsMap:(NSArray<BRZFeatureFlag *> *)featureFlags {
  NSMutableArray<NSDictionary *> *mappedFlags = [NSMutableArray array];
  for (BRZFeatureFlag *flag in featureFlags) {
    NSError* error = nil;
    id flagJSON = [NSJSONSerialization JSONObjectWithData:[flag json]
                                                  options:NSJSONReadingMutableContainers
                                                    error:&error];
    if (!error) {
      [mappedFlags addObject:flagJSON];
    } else {
      NSLog(@"Failed to serialize Feature Flag with error: %@", error);
    }
  }

  return mappedFlags;
}


// MARK: - BrazeSDKAuthDelegate
- (void)braze:(Braze * _Nonnull)braze sdkAuthenticationFailedWithError:(BRZSDKAuthenticationError * _Nonnull)error {
  if (self.sdkAuthCallbackID) {
    NSMutableDictionary *sdkAuthErrorEvent = [[NSMutableDictionary alloc] init];
    sdkAuthErrorEvent[@"signature"] = error.signature;
    sdkAuthErrorEvent[@"errorCode"] = @(error.code);
    sdkAuthErrorEvent[@"errorReason"] = error.reason;
    sdkAuthErrorEvent[@"userId"] = error.userId;
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                  messageAsDictionary:sdkAuthErrorEvent];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.sdkAuthCallbackID];
  }
}

// MARK: - Cordova Helper Methods
- (void)sendCordovaErrorPluginResultWithString:(NSString *)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithString:(NSString *)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithInt:(NSUInteger)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithDouble:(double)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithBool:(BOOL)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithArray:(NSArray *)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultWithDictionary:(NSDictionary *)resultMessage andCommand:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultMessage];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendCordovaSuccessPluginResultAsNull:(CDVInvokedUrlCommand *)command {
  CDVPluginResult *pluginResult = nil;
  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:(NSString *)[NSNull null]];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

// MARK: - Helper Methods

/**
 * Takes an NSString, trim whitespaces, and return the sanitized NSString converted to lowercase.
 */
- (NSString *)sanitizeString:(NSString *)inputString {
  NSString *trimmedString = [inputString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return ([trimmedString lowercaseString]);
}

/**
 * Map an `NSString` to a JavaScript-representable version.
 * Escape characters are lost in translation, so we need to manually insert them back in.
 */
- (NSString *)escapeStringForJavaScript:(NSString *)input {
  NSMutableString *escapedString = [NSMutableString stringWithString:input];

  [escapedString replaceOccurrencesOfString:@"\\"
                                 withString:@"\\\\"
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  [escapedString replaceOccurrencesOfString:@"\""
                                 withString:@"\\\""
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  [escapedString replaceOccurrencesOfString:@"\'"
                                 withString:@"\\\'"
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  [escapedString replaceOccurrencesOfString:@"\n"
                                 withString:@"\\n"
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  [escapedString replaceOccurrencesOfString:@"\r"
                                 withString:@"\\r"
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  [escapedString replaceOccurrencesOfString:@"\t"
                                 withString:@"\\t"
                                    options:NSLiteralSearch
                                      range:NSMakeRange(0, [escapedString length])];

  return escapedString;
}

- (BRZTrackingProperty *)convertTrackingProperty:(NSString *)propertyString {
  if ([propertyString isEqualToString:@"all_custom_attributes"]) {
    return BRZTrackingProperty.allCustomAttributes;
  } else if ([propertyString isEqualToString:@"all_custom_events"]) {
    return BRZTrackingProperty.allCustomEvents;
  } else if ([propertyString isEqualToString:@"analytics_events"]) {
    return BRZTrackingProperty.analyticsEvents;
  } else if ([propertyString isEqualToString:@"attribution_data"]) {
    return BRZTrackingProperty.attributionData;
  } else if ([propertyString isEqualToString:@"country"]) {
    return BRZTrackingProperty.country;
  } else if ([propertyString isEqualToString:@"dob"]) {
    return BRZTrackingProperty.dateOfBirth;
  } else if ([propertyString isEqualToString:@"device_data"]) {
    return BRZTrackingProperty.deviceData;
  } else if ([propertyString isEqualToString:@"email"]) {
    return BRZTrackingProperty.email;
  } else if ([propertyString isEqualToString:@"email_subscription_state"]) {
    return BRZTrackingProperty.emailSubscriptionState;
  } else if ([propertyString isEqualToString:@"everything"]) {
    return BRZTrackingProperty.everything;
  } else if ([propertyString isEqualToString:@"first_name"]) {
    return BRZTrackingProperty.firstName;
  } else if ([propertyString isEqualToString:@"gender"]) {
    return BRZTrackingProperty.gender;
  } else if ([propertyString isEqualToString:@"home_city"]) {
    return BRZTrackingProperty.homeCity;
  } else if ([propertyString isEqualToString:@"language"]) {
    return BRZTrackingProperty.language;
  } else if ([propertyString isEqualToString:@"last_name"]) {
    return BRZTrackingProperty.lastName;
  } else if ([propertyString isEqualToString:@"notification_subscription_state"]) {
    return BRZTrackingProperty.notificationSubscriptionState;
  } else if ([propertyString isEqualToString:@"phone_number"]) {
    return BRZTrackingProperty.phoneNumber;
  } else if ([propertyString isEqualToString:@"push_token"]) {
    return BRZTrackingProperty.pushToken;
  } else {
    NSLog(@"Invalid tracking property: %@", propertyString);
    return nil;
  }
}

// MARK: - BrazeInAppMessagePresenter

/// Receives every in-app message BrazeKit triggers. This is the only hand-off BrazeKit offers, so
/// nothing can reach a screen without passing through here.
///
/// Deciding WHEN a message may display is separate from deciding WHO draws it, and WHEN comes first,
/// matching the pre-16 plugin: hold until the app has called getNextInApp() once, then present as they
/// arrive. WHO renders it is the only thing this plugin changes — a message carrying our payload goes
/// to JS to be drawn in-app, anything else is forwarded to Braze's own UI and renders exactly as before.
- (void)presentMessage:(BRZInAppMessageRaw *)message {
  if (message == nil) {
    return;
  }

  // Stake custom: WHEN. Held in our own array rather than re-enqueued onto Braze's stack: Braze drains
  // that stack through -presentNext, which never consults the presenter, so a payload left there could
  // be drawn by Braze without ever meeting the claim test. Nothing is inspected or sent to JS while a
  // message waits, and its context is untouched, so it presents later exactly as it would have now.
  if (!hasRequestedInAppDisplay) {
    [heldInAppMessages addObject:message];
    return;
  }

  [self routeInAppMessage:message];
}

/// Dismisses the visible message and drops everything queued, on `changeUser` or `wipeData`.
///
/// Forwarded to the private UI so it can clear its own stack, followup message and click-action state —
/// skipping it would leave a Braze message on screen belonging to the previous user.
- (void)dismissWithReason:(enum BRZInAppMessageDismissalReason)reason {
  [self clearPendingInAppMessages];
  [self.inAppMessageUI dismissWithReason:reason];
}

/// Decides who draws `message`, once the app has said it is ready.
///
/// Split from -presentMessage: so getNextInApp() can release a held message down the identical path.
- (void)routeInAppMessage:(BRZInAppMessageRaw *)message {
  // Stake custom: the pre-16 plugin presented every in-app message without animation.
  message.animateIn = NO;
  message.animateOut = NO;

  // Stake custom: WHO renders it. Only a message carrying our payload is claimed; an explicit
  // subscribeToInAppMessage(useBrazeUI = YES) opts out of claiming altogether.
  BOOL retainForJs = isInAppMessageSubscribed
                     && !useBrazeUIForInAppMessages
                     && self.subscribeToInAppMessageCallbackID != nil
                     && [self isStakeRenderedInAppMessage:message];
  if (!retainForJs) {
    [self.inAppMessageUI presentMessage:message];
    return;
  }

  NSInteger retainedId = [self retainInAppMessage:message];
  NSData *inAppMessageData = [message json];
  NSString *inAppMessageString = [[NSString alloc] initWithData:inAppMessageData encoding:NSUTF8StringEncoding];
  NSLog(@"In-app message received: %@", inAppMessageString);

  // Stake custom: the callback carries the *unescaped* JSON. escapeStringForJavaScript exists for the
  // inline evalJs statement below only; on a plugin result it yields {\"version\":…}, which
  // JSON.parse rejects.
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                          messageAsDictionary:@{@"id": @(retainedId), @"message": inAppMessageString ?: @""}];
  [result setKeepCallbackAsBool:YES];
  [self.commandDelegate sendPluginResult:result callbackId:self.subscribeToInAppMessageCallbackID];

  // Send in-app message string back to JavaScript in an `inAppMessageReceived` event
  NSString* jsStatement = [NSString stringWithFormat:@"app.inAppMessageReceived('%@');", [self escapeStringForJavaScript:inAppMessageString]];
  [self.commandDelegate evalJs:jsStatement];

  // Stake custom: the message is ours now. Returning without forwarding to Braze's UI is all it takes —
  // BrazeKit hands a message over and forgets it, so there is no stack to remove it from and nothing to
  // discard. JS decides from here via showInAppMessage(id) / releaseInAppMessage(id).
}

@end
