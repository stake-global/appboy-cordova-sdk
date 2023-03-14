package com.appboy.cordova

import android.content.Context

class AppboyPlugin : CordovaPlugin() {
    private var mPluginInitializationFinished = false
    private var mDisableAutoStartSessions = false
    private var mApplicationContext: Context? = null
    var iInAppMessageManagerListener: CustomInAppMessageManagerListener? = null
    private val mFeedSubscriberMap: Map<String, IEventSubscriber<FeedUpdatedEvent>> =
        ConcurrentHashMap()

    @Override
    protected fun pluginInitialize() {
        mApplicationContext = this.cordova.getActivity().getApplicationContext()

        // Configure Appboy using the preferences from the config.xml file passed to our plugin
        configureFromCordovaPreferences(this.preferences)

        // Since we've likely passed the first Application.onCreate() (due to the plugin lifecycle), lets call the
        // in-app message manager and session handling now
        BrazeInAppMessageManager.getInstance()
            .registerInAppMessageManager(this.cordova.getActivity())
        mPluginInitializationFinished = true
    }

    @Override
    @Throws(JSONException::class)
    fun execute(action: String, args: JSONArray, callbackContext: CallbackContext): Boolean {
        initializePluginIfAppropriate()
        Log.i(TAG, "Received $action with the following arguments: $args")
        when (action) {
            "startSessionTracking" -> {
                mDisableAutoStartSessions = false
                return true
            }
            "getNextInApp" -> {
                Log.i(TAG, "Received getNextInApp")
                iInAppMessageManagerListener.inAppDisplayAttempts += 1
                return BrazeInAppMessageManager.getInstance().requestDisplayInAppMessage()
            }
            "registerAppboyPushMessages" -> {
                Braze.getInstance(mApplicationContext).setRegisteredPushToken(args.getString(0))
                return true
            }
            "changeUser" -> {
                Braze.getInstance(mApplicationContext).changeUser(args.getString(0))
                return true
            }
            "logCustomEvent" -> {
                var properties: BrazeProperties? = null
                if (args.get(1) !== JSONObject.NULL) {
                    properties = BrazeProperties(args.getJSONObject(1))
                }
                Braze.getInstance(mApplicationContext).logCustomEvent(args.getString(0), properties)
                return true
            }
            "logPurchase" -> {
                var currencyCode = "USD"
                if (args.get(2) !== JSONObject.NULL) {
                    currencyCode = args.getString(2)
                }
                var quantity = 1
                if (args.get(3) !== JSONObject.NULL) {
                    quantity = args.getInt(3)
                }
                var properties: BrazeProperties? = null
                if (args.get(4) !== JSONObject.NULL) {
                    properties = BrazeProperties(args.getJSONObject(4))
                }
                Braze.getInstance(mApplicationContext).logPurchase(
                    args.getString(0),
                    currencyCode,
                    BigDecimal(args.getDouble(1)),
                    quantity,
                    properties
                )
                return true
            }
            "wipeData" -> {
                Braze.wipeData(mApplicationContext)
                mPluginInitializationFinished = false
                return true
            }
            "enableSdk" -> {
                Braze.enableSdk(mApplicationContext)
                return true
            }
            "disableSdk" -> {
                Braze.disableSdk(mApplicationContext)
                mPluginInitializationFinished = false
                return true
            }
            "requestImmediateDataFlush" -> {
                Braze.getInstance(mApplicationContext).requestImmediateDataFlush()
                return true
            }
            "requestContentCardsRefresh" -> {
                Braze.getInstance(mApplicationContext).requestContentCardsRefresh(false)
                return true
            }
            "getDeviceId" -> {
                callbackContext.success(Braze.getInstance(mApplicationContext).getDeviceId())
                return true
            }
        }

        // User methods
        val currentUser: BrazeUser = Braze.getInstance(mApplicationContext).getCurrentUser()
        if (currentUser != null) {
            when (action) {
                "setUserAttributionData" -> {
                    currentUser.setAttributionData(
                        AttributionData(
                            args.getString(0),
                            args.getString(1),
                            args.getString(2),
                            args.getString(3)
                        )
                    )
                    return true
                }
                "setStringCustomUserAttribute" -> {
                    currentUser.setCustomUserAttribute(args.getString(0), args.getString(1))
                    return true
                }
                "unsetCustomUserAttribute" -> {
                    currentUser.unsetCustomUserAttribute(args.getString(0))
                    return true
                }
                "setBoolCustomUserAttribute" -> {
                    currentUser.setCustomUserAttribute(args.getString(0), args.getBoolean(1))
                    return true
                }
                "setIntCustomUserAttribute" -> {
                    currentUser.setCustomUserAttribute(args.getString(0), args.getInt(1))
                    return true
                }
                "setDoubleCustomUserAttribute" -> {
                    currentUser.setCustomUserAttribute(
                        args.getString(0),
                        args.getDouble(1) as Float
                    )
                    return true
                }
                "setDateCustomUserAttribute" -> {
                    currentUser.setCustomUserAttributeToSecondsFromEpoch(
                        args.getString(0),
                        args.getLong(1)
                    )
                    return true
                }
                "incrementCustomUserAttribute" -> {
                    currentUser.incrementCustomUserAttribute(args.getString(0), args.getInt(1))
                    return true
                }
                "setCustomUserAttributeArray" -> {
                    val attributes = parseJSONArrayToStringArray(args.getJSONArray(1))
                    currentUser.setCustomAttributeArray(args.getString(0), attributes)
                    return true
                }
                "addToCustomAttributeArray" -> {
                    currentUser.addToCustomAttributeArray(args.getString(0), args.getString(1))
                    return true
                }
                "removeFromCustomAttributeArray" -> {
                    currentUser.removeFromCustomAttributeArray(args.getString(0), args.getString(1))
                    return true
                }
                "setFirstName" -> {
                    currentUser.setFirstName(args.getString(0))
                    return true
                }
                "setLastName" -> {
                    currentUser.setLastName(args.getString(0))
                    return true
                }
                "setEmail" -> {
                    currentUser.setEmail(args.getString(0))
                    return true
                }
                "setGender" -> {
                    val gender: String = args.getString(0).toLowerCase()
                    when (gender) {
                        "f" -> currentUser.setGender(Gender.FEMALE)
                        "m" -> currentUser.setGender(Gender.MALE)
                        "n" -> currentUser.setGender(Gender.NOT_APPLICABLE)
                        "o" -> currentUser.setGender(Gender.OTHER)
                        "p" -> currentUser.setGender(Gender.PREFER_NOT_TO_SAY)
                        "u" -> currentUser.setGender(Gender.UNKNOWN)
                    }
                    return true
                }
                "addAlias" -> {
                    currentUser.addAlias(args.getString(0), args.getString(1))
                    return true
                }
                "setDateOfBirth" -> {
                    val month: Month = Month.getMonth(args.getInt(1) - 1)
                    currentUser.setDateOfBirth(args.getInt(0), month, args.getInt(2))
                    return true
                }
                "setCountry" -> {
                    currentUser.setCountry(args.getString(0))
                    return true
                }
                "setHomeCity" -> {
                    currentUser.setHomeCity(args.getString(0))
                    return true
                }
                "setPhoneNumber" -> {
                    currentUser.setPhoneNumber(args.getString(0))
                    return true
                }
                "setPushNotificationSubscriptionType" -> {
                    val subscriptionType: String = args.getString(0)
                    when (subscriptionType) {
                        "opted_in" -> currentUser.setPushNotificationSubscriptionType(
                            NotificationSubscriptionType.OPTED_IN
                        )
                        "subscribed" -> currentUser.setPushNotificationSubscriptionType(
                            NotificationSubscriptionType.SUBSCRIBED
                        )
                        "unsubscribed" -> currentUser.setPushNotificationSubscriptionType(
                            NotificationSubscriptionType.UNSUBSCRIBED
                        )
                    }
                    return true
                }
                "setEmailNotificationSubscriptionType" -> {
                    val subscriptionType: String = args.getString(0)
                    when (subscriptionType) {
                        "opted_in" -> currentUser.setEmailNotificationSubscriptionType(
                            NotificationSubscriptionType.OPTED_IN
                        )
                        "subscribed" -> currentUser.setEmailNotificationSubscriptionType(
                            NotificationSubscriptionType.SUBSCRIBED
                        )
                        "unsubscribed" -> currentUser.setEmailNotificationSubscriptionType(
                            NotificationSubscriptionType.UNSUBSCRIBED
                        )
                    }
                    return true
                }
                "setLanguage" -> {
                    currentUser.setLanguage(args.getString(0))
                    return true
                }
                "addToSubscriptionGroup" -> {
                    currentUser.addToSubscriptionGroup(args.getString(0))
                    return true
                }
                "removeFromSubscriptionGroup" -> {
                    currentUser.removeFromSubscriptionGroup(args.getString(0))
                    return true
                }
                "requestPushPermission" -> {
                    PermissionUtils.requestPushPermissionPrompt(cordova.getActivity())
                    return true
                }
            }
        }

        // Launching activities
        val intent: Intent
        when (action) {
            "launchNewsFeed" -> {
                intent = Intent(mApplicationContext, AppboyFeedActivity::class.java)
                this.cordova.getActivity().startActivity(intent)
                return true
            }
            "launchContentCards" -> {
                intent = Intent(mApplicationContext, ContentCardsActivity::class.java)
                this.cordova.getActivity().startActivity(intent)
                return true
            }
        }
        when (action) {
            GET_NEWS_FEED_METHOD, GET_CARD_COUNT_FOR_CATEGORIES_METHOD, GET_UNREAD_CARD_COUNT_FOR_CATEGORIES_METHOD -> return handleNewsFeedGetters(
                action,
                args,
                callbackContext
            )
        }
        when (action) {
            GET_CONTENT_CARDS_FROM_SERVER_METHOD, GET_CONTENT_CARDS_FROM_CACHE_METHOD -> return handleContentCardsUpdateGetters(
                action,
                callbackContext
            )
            LOG_CONTENT_CARDS_CLICKED_METHOD, LOG_CONTENT_CARDS_DISMISSED_METHOD, LOG_CONTENT_CARDS_IMPRESSION_METHOD -> return handleContentCardsLogMethods(
                action,
                args,
                callbackContext
            )
        }
        Log.d(TAG, "Failed to execute for action: $action")
        return false
    }

    @Override
    fun onPause(multitasking: Boolean) {
        super.onPause(multitasking)
        initializePluginIfAppropriate()
        BrazeInAppMessageManager.getInstance()
            .unregisterInAppMessageManager(this.cordova.getActivity())
    }

    @Override
    fun onResume(multitasking: Boolean) {
        super.onResume(multitasking)
        initializePluginIfAppropriate()
        // Registers the BrazeInAppMessageManager for the current Activity. This Activity will now listen for
        // in-app messages from Braze.
        BrazeInAppMessageManager.getInstance()
            .registerInAppMessageManager(this.cordova.getActivity())
    }

    @Override
    fun onStart() {
        super.onStart()
        initializePluginIfAppropriate()
        if (!mDisableAutoStartSessions) {
            Braze.getInstance(mApplicationContext).openSession(this.cordova.getActivity())
        }
    }

    @Override
    fun onStop() {
        super.onStop()
        initializePluginIfAppropriate()
        if (!mDisableAutoStartSessions) {
            Braze.getInstance(mApplicationContext).closeSession(this.cordova.getActivity())
        }
    }

    /**
     * Calls [AppboyPlugin.pluginInitialize] if [AppboyPlugin.mPluginInitializationFinished] is false.
     */
    private fun initializePluginIfAppropriate() {
        if (!mPluginInitializationFinished) {
            pluginInitialize()
        }
    }

    /**
     * Calls [Braze.configure] using the values found from the [CordovaPreferences].
     *
     * @param cordovaPreferences the preferences used to initialize this plugin
     */
    private fun configureFromCordovaPreferences(cordovaPreferences: CordovaPreferences) {
        BrazeLogger.d(TAG, "Setting Cordova preferences: " + cordovaPreferences.getAll())

        // Set the log level
        if (cordovaPreferences.contains(APPBOY_LOG_LEVEL_PREFERENCE)) {
            BrazeLogger.setLogLevel(
                cordovaPreferences.getInteger(
                    APPBOY_LOG_LEVEL_PREFERENCE,
                    Log.INFO
                )
            )
        }

        // Disable auto starting sessions
        if (cordovaPreferences.getBoolean(DISABLE_AUTO_START_SESSIONS_PREFERENCE, false)) {
            BrazeLogger.d(TAG, "Disabling session auto starts")
            mDisableAutoStartSessions = true
        }

        // Set the values used in the config builder
        val configBuilder: BrazeConfig.Builder = Builder()

        // Set the flavor
        configBuilder.setSdkFlavor(SdkFlavor.CORDOVA)
            .setSdkMetadata(EnumSet.of(BrazeSdkMetadata.CORDOVA))
        if (cordovaPreferences.contains(APPBOY_API_KEY_PREFERENCE)) {
            configBuilder.setApiKey(cordovaPreferences.getString(APPBOY_API_KEY_PREFERENCE, null))
        }
        if (cordovaPreferences.contains(SMALL_NOTIFICATION_ICON_PREFERENCE)) {
            configBuilder.setSmallNotificationIcon(
                cordovaPreferences.getString(
                    SMALL_NOTIFICATION_ICON_PREFERENCE, null
                )
            )
        }
        if (cordovaPreferences.contains(LARGE_NOTIFICATION_ICON_PREFERENCE)) {
            configBuilder.setLargeNotificationIcon(
                cordovaPreferences.getString(
                    LARGE_NOTIFICATION_ICON_PREFERENCE, null
                )
            )
        }
        if (cordovaPreferences.contains(DEFAULT_NOTIFICATION_ACCENT_COLOR_PREFERENCE)) {
            configBuilder.setDefaultNotificationAccentColor(
                parseNumericPreferenceAsInteger(
                    cordovaPreferences.getString(
                        DEFAULT_NOTIFICATION_ACCENT_COLOR_PREFERENCE, "0"
                    )
                )
            )
        }
        if (cordovaPreferences.contains(DEFAULT_SESSION_TIMEOUT_PREFERENCE)) {
            configBuilder.setSessionTimeout(
                parseNumericPreferenceAsInteger(
                    cordovaPreferences.getString(
                        DEFAULT_SESSION_TIMEOUT_PREFERENCE, "10"
                    )
                )
            )
        }
        if (cordovaPreferences.contains(SET_HANDLE_PUSH_DEEP_LINKS_AUTOMATICALLY_PREFERENCE)) {
            configBuilder.setHandlePushDeepLinksAutomatically(
                cordovaPreferences.getBoolean(
                    SET_HANDLE_PUSH_DEEP_LINKS_AUTOMATICALLY_PREFERENCE, true
                )
            )
        }
        if (cordovaPreferences.contains(AUTOMATIC_FIREBASE_PUSH_REGISTRATION_ENABLED_PREFERENCE)) {
            configBuilder.setIsFirebaseCloudMessagingRegistrationEnabled(
                cordovaPreferences.getBoolean(
                    AUTOMATIC_FIREBASE_PUSH_REGISTRATION_ENABLED_PREFERENCE, true
                )
            )
        }
        if (cordovaPreferences.contains(FCM_SENDER_ID_PREFERENCE)) {
            configBuilder.setFirebaseCloudMessagingSenderIdKey(
                parseNumericPreferenceAsString(
                    cordovaPreferences.getString(
                        FCM_SENDER_ID_PREFERENCE, null
                    )
                )
            )
        }
        if (cordovaPreferences.contains(ENABLE_LOCATION_PREFERENCE)) {
            configBuilder.setIsLocationCollectionEnabled(
                cordovaPreferences.getBoolean(
                    ENABLE_LOCATION_PREFERENCE, false
                )
            )
        }
        if (cordovaPreferences.contains(ENABLE_GEOFENCES_PREFERENCE)) {
            configBuilder.setGeofencesEnabled(
                cordovaPreferences.getBoolean(
                    ENABLE_GEOFENCES_PREFERENCE, false
                )
            )
        }
        if (cordovaPreferences.contains(CUSTOM_API_ENDPOINT_PREFERENCE)) {
            val customApiEndpoint: String = cordovaPreferences.getString(
                CUSTOM_API_ENDPOINT_PREFERENCE, ""
            )
            if (!customApiEndpoint.equals("")) {
                configBuilder.setCustomEndpoint(customApiEndpoint)
            }
        }
        val enableRequestFocusFix: Boolean = cordovaPreferences.getBoolean(
            ENABLE_CORDOVA_WEBVIEW_REQUEST_FOCUS_FIX_PREFERENCE, true
        )
        iInAppMessageManagerListener = CustomInAppMessageManagerListener(this.cordova.getActivity())
        BrazeInAppMessageManager.getInstance()
            .setCustomInAppMessageManagerListener(iInAppMessageManagerListener)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P && enableRequestFocusFix) {
            // Addresses Cordova bug in https://issuetracker.google.com/issues/36915710
            BrazeInAppMessageManager.getInstance()
                .setCustomInAppMessageViewWrapperFactory(CordovaInAppMessageViewWrapperFactory())
        }
        Braze.configure(mApplicationContext, configBuilder.build())
    }

    @Throws(JSONException::class)
    private fun handleNewsFeedGetters(
        action: String,
        args: JSONArray,
        callbackContext: CallbackContext
    ): Boolean {
        var feedUpdatedSubscriber: IEventSubscriber<FeedUpdatedEvent?>? = null
        var requestingFeedUpdateFromCache = false
        val braze: Braze = Braze.getInstance(mApplicationContext)
        val callbackId: String = callbackContext.getCallbackId()
        when (action) {
            GET_CARD_COUNT_FOR_CATEGORIES_METHOD -> {
                val categories: EnumSet<CardCategory> = getCategoriesFromJSONArray(args)
                feedUpdatedSubscriber = IEventSubscriber<FeedUpdatedEvent> { event ->
                    // Each callback context is by default made to only be called once and is afterwards "finished". We want to ensure
                    // that we never try to call the same callback twice. This could happen since we don't know the ordering of the feed
                    // subscription callbacks from the cache.
                    if (!callbackContext.isFinished()) {
                        callbackContext.success(event.getCardCount(categories))
                    }

                    // Remove this listener from the map and from Appboy
                    braze.removeSingleSubscription(
                        mFeedSubscriberMap[callbackId],
                        FeedUpdatedEvent::class.java
                    )
                    mFeedSubscriberMap.remove(callbackId)
                }
                requestingFeedUpdateFromCache = true
            }
            GET_UNREAD_CARD_COUNT_FOR_CATEGORIES_METHOD -> {
                val categories: EnumSet<CardCategory> = getCategoriesFromJSONArray(args)
                feedUpdatedSubscriber = IEventSubscriber<FeedUpdatedEvent> { event ->
                    if (!callbackContext.isFinished()) {
                        callbackContext.success(event.getUnreadCardCount(categories))
                    }

                    // Remove this listener from the map and from Appboy
                    braze.removeSingleSubscription(
                        mFeedSubscriberMap[callbackId],
                        FeedUpdatedEvent::class.java
                    )
                    mFeedSubscriberMap.remove(callbackId)
                }
                requestingFeedUpdateFromCache = true
            }
            GET_NEWS_FEED_METHOD -> {
                val categories: EnumSet<CardCategory> = getCategoriesFromJSONArray(args)
                feedUpdatedSubscriber = IEventSubscriber<FeedUpdatedEvent> { event ->
                    if (!callbackContext.isFinished()) {
                        val cards: List<Card> = event.getFeedCards(categories)
                        val result = JSONArray()
                        var i = 0
                        while (i < cards.size()) {
                            result.put(cards[i].forJsonPut())
                            i++
                        }
                        callbackContext.success(result)
                    }

                    // Remove this listener from the map and from Appboy
                    braze.removeSingleSubscription(
                        mFeedSubscriberMap[callbackId],
                        FeedUpdatedEvent::class.java
                    )
                    mFeedSubscriberMap.remove(callbackId)
                }
                requestingFeedUpdateFromCache = false
            }
        }
        if (feedUpdatedSubscriber != null) {
            // Put the subscriber into a map so we can remove it later from future subscriptions
            mFeedSubscriberMap.put(callbackId, feedUpdatedSubscriber)
            braze.subscribeToFeedUpdates(feedUpdatedSubscriber)
            if (requestingFeedUpdateFromCache) {
                braze.requestFeedRefreshFromCache()
            } else {
                braze.requestFeedRefresh()
            }
        }
        return true
    }

    private fun handleContentCardsUpdateGetters(
        action: String,
        callbackContext: CallbackContext
    ): Boolean {
        // Setup a one-time subscriber for the update event
        val subscriber: IEventSubscriber<ContentCardsUpdatedEvent> =
            object : IEventSubscriber<ContentCardsUpdatedEvent?>() {
                @Override
                fun trigger(event: ContentCardsUpdatedEvent) {
                    Braze.getInstance(mApplicationContext)
                        .removeSingleSubscription(this, ContentCardsUpdatedEvent::class.java)

                    // Map the content cards to JSON and return to the client
                    callbackContext.success(ContentCardUtils.mapContentCards(event.getAllCards()))
                }
            }
        Braze.getInstance(mApplicationContext).subscribeToContentCardsUpdates(subscriber)
        val updateFromCache = action.equals(GET_CONTENT_CARDS_FROM_CACHE_METHOD)
        Braze.getInstance(mApplicationContext).requestContentCardsRefresh(updateFromCache)
        return true
    }

    private fun handleContentCardsLogMethods(
        action: String,
        args: JSONArray,
        callbackContext: CallbackContext
    ): Boolean {
        val braze: Braze = Braze.getInstance(mApplicationContext)
        val cardId: String
        if (args.length() !== 1) {
            Log.d(
                TAG,
                "Cannot handle logging method for $action due to improper number of arguments. Args: $args"
            )
            callbackContext.error("Failed for action $action")
            return false
        }
        cardId = try {
            args.getString(0)
        } catch (e: JSONException) {
            Log.e(TAG, "Failed to parse card id from args: $args", e)
            callbackContext.error("Failed for action $action")
            return false
        }

        // Get the list of cards
        // Only obtaining the current list of cached cards is ok since
        // no id passed in could refer to a card on the server that isn't
        // contained in the list of cached cards
        val cachedContentCards: List<Card> = braze.getCachedContentCards()

        // Get the desired card by its id
        val desiredCard: Card = ContentCardUtils.getCardById(cachedContentCards, cardId)
        if (desiredCard == null) {
            Log.w(TAG, "Couldn't find card in list of cached cards")
            callbackContext.error("Failed for action $action")
            return false
        }
        when (action) {
            LOG_CONTENT_CARDS_CLICKED_METHOD -> desiredCard.logClick()
            LOG_CONTENT_CARDS_DISMISSED_METHOD -> desiredCard.setDismissed(true)
            LOG_CONTENT_CARDS_IMPRESSION_METHOD -> desiredCard.logImpression()
        }

        // Return success to the callback
        callbackContext.success()
        return true
    }

    companion object {
        private const val TAG = "BrazeCordova"

        // Preference keys found in the config.xml
        private const val APPBOY_API_KEY_PREFERENCE = "com.appboy.api_key"
        private const val AUTOMATIC_FIREBASE_PUSH_REGISTRATION_ENABLED_PREFERENCE =
            "com.appboy.firebase_cloud_messaging_registration_enabled"
        private const val FCM_SENDER_ID_PREFERENCE = "com.appboy.android_fcm_sender_id"
        private const val APPBOY_LOG_LEVEL_PREFERENCE = "com.appboy.android_log_level"
        private const val SMALL_NOTIFICATION_ICON_PREFERENCE =
            "com.appboy.android_small_notification_icon"
        private const val LARGE_NOTIFICATION_ICON_PREFERENCE =
            "com.appboy.android_large_notification_icon"
        private const val DEFAULT_NOTIFICATION_ACCENT_COLOR_PREFERENCE =
            "com.appboy.android_notification_accent_color"
        private const val DEFAULT_SESSION_TIMEOUT_PREFERENCE =
            "com.appboy.android_default_session_timeout"
        private const val SET_HANDLE_PUSH_DEEP_LINKS_AUTOMATICALLY_PREFERENCE =
            "com.appboy.android_handle_push_deep_links_automatically"
        private const val CUSTOM_API_ENDPOINT_PREFERENCE = "com.appboy.android_api_endpoint"
        private const val ENABLE_LOCATION_PREFERENCE = "com.appboy.enable_location_collection"
        private const val ENABLE_GEOFENCES_PREFERENCE = "com.appboy.geofences_enabled"
        private const val DISABLE_AUTO_START_SESSIONS_PREFERENCE =
            "com.appboy.android_disable_auto_session_tracking"

        /**
         * When applied, restricts the SDK from taking
         * focus away from the Cordova WebView on affected API versions.
         */
        private const val ENABLE_CORDOVA_WEBVIEW_REQUEST_FOCUS_FIX_PREFERENCE =
            "com.braze.android_apply_cordova_webview_focus_request_fix"

        // Numeric preference prefix
        private const val NUMERIC_PREFERENCE_PREFIX = "str_"

        // News Feed method names
        private const val GET_NEWS_FEED_METHOD = "getNewsFeed"
        private const val GET_CARD_COUNT_FOR_CATEGORIES_METHOD = "getCardCountForCategories"
        private const val GET_UNREAD_CARD_COUNT_FOR_CATEGORIES_METHOD =
            "getUnreadCardCountForCategories"

        // Content Card method names
        private const val GET_CONTENT_CARDS_FROM_SERVER_METHOD = "getContentCardsFromServer"
        private const val GET_CONTENT_CARDS_FROM_CACHE_METHOD = "getContentCardsFromCache"
        private const val LOG_CONTENT_CARDS_CLICKED_METHOD = "logContentCardClicked"
        private const val LOG_CONTENT_CARDS_IMPRESSION_METHOD = "logContentCardImpression"
        private const val LOG_CONTENT_CARDS_DISMISSED_METHOD = "logContentCardDismissed"
        @Throws(JSONException::class)
        private fun getCategoriesFromJSONArray(jsonArray: JSONArray): EnumSet<CardCategory> {
            val categories: EnumSet<CardCategory> = EnumSet.noneOf(CardCategory::class.java)
            for (i in 0 until jsonArray.length()) {
                val category: String = jsonArray.getString(i)
                var categoryArgument: CardCategory
                categoryArgument = if (category.equals("all")) {
                    // "All categories" maps to a enumset and not a specific enum so we have to return that here
                    return CardCategory.getAllCategories()
                } else {
                    CardCategory.get(category)
                }
                if (categoryArgument != null) {
                    categories.add(categoryArgument)
                } else {
                    Log.w(TAG, "Tried to add unknown card category: $category")
                }
            }
            return categories
        }

        @Throws(JSONException::class)
        private fun parseJSONArrayToStringArray(jsonArray: JSONArray): Array<String?> {
            val length: Int = jsonArray.length()
            val array = arrayOfNulls<String>(length)
            for (i in 0 until length) {
                array[i] = jsonArray.getString(i)
            }
            return array
        }

        /**
         * Parses the preference that is optionally prefixed with a constant.
         *
         * I.e. {"PREFIX-value", "value"} -> {"value"}
         */
        private fun parseNumericPreferenceAsString(preference: String?): String? {
            if (preference != null && preference.startsWith(NUMERIC_PREFERENCE_PREFIX)) {
                val preferenceValue: String =
                    preference.substring(NUMERIC_PREFERENCE_PREFIX.length(), preference.length())
                BrazeLogger.d(
                    TAG,
                    "Parsed numeric preference $preference into value: $preferenceValue"
                )
                return preferenceValue
            }
            return preference
        }

        /**
         * Parses the preference that is optionally prefixed with a constant.
         *
         * I.e. {"PREFIX-value", "value"} -> {"value"}
         */
        private fun parseNumericPreferenceAsInteger(preference: String?): Int {
            var preferenceValue = preference
            if (preference != null && preference.startsWith(NUMERIC_PREFERENCE_PREFIX)) {
                preferenceValue =
                    preference.substring(NUMERIC_PREFERENCE_PREFIX.length(), preference.length())
                BrazeLogger.d(
                    TAG,
                    "Parsed numeric preference $preference into value: $preferenceValue"
                )
            }

            // Parse the string as an integer. Note that this is the same decoding used in CordovaPreferences
            return Long.decode(preferenceValue) as Long.toInt()
        }
    }
}