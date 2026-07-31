<img src="https://github.com/braze-inc/braze-cordova-sdk/blob/master/braze-logo.png" width="300" title="Braze Logo" />

# Braze Cordova SDK — Stake fork

> **This is Stake's fork of [braze-inc/braze-cordova-sdk](https://github.com/braze-inc/braze-cordova-sdk), tracking upstream 16.0.1.**
>
> It is an **equal fork**: upstream verbatim, plus a small Stake delta where every block is commented
> `// Stake custom:` so the next upstream bump can be re-applied by diffing against the upstream tag.
> Keep it that way — a change that cannot be described as one of those blocks probably belongs
> upstream or in the app.
>
> **What the delta does, and why the fork exists at all:**
>
> * **`promptForPush()` (iOS)** — ask for push permission at a moment the app chooses, rather than on
>   first launch. This was the original and only reason for the fork.
> * **Display timing** — Braze's automatic display is suppressed; messages are held until the app
>   calls `getNextInApp()` once, then present as they arrive.
> * **Rendering ownership** — `subscribeToInAppMessage(cb, err, useBrazeUI = false)` retains a
>   claimed message and hands it to JS instead of drawing it, so the app can render Stake's own
>   in-app messages with its own components. JS returns anything it does not own via
>   `showInAppMessage(id)`, or discards it with `releaseInAppMessage(id)`.
>
> The **["Stake fork" preamble in CHANGELOG.md](./CHANGELOG.md#stake-fork)** is the full reference —
> the claim marker, the two interception points, and the smaller customizations. Read it before
> changing anything under `src/`.
>
> **Consumed by `stake-frontend`** via a branch ref in `apps/mobile-app/package.json`, not by the
> `cordova plugin add` commands below. After changing anything here, bump that ref, run
> `npx cap sync ios && npx cap sync android`, and confirm the synced copies under
> `ios/capacitor-cordova-ios-plugins/` and `android/capacitor-cordova-android-plugins/` are
> byte-identical to `node_modules/braze-cordova-sdk` — a stale synced copy has cost a debugging
> session before.

Everything below this line is upstream's own README.

---

Effective marketing automation is an essential part of successfully scaling and managing your business. Braze empowers you to build better customer relationships through a seamless, multi-channel approach that addresses all aspects of the user life cycle. Braze helps you engage your users on an ongoing basis. View the following resources for details and we'll have you up and running in no time!

See our instructions for [Integrating the Braze Cordova SDK](https://www.braze.com/docs/developer_guide/platforms/cordova/sdk_integration) into your Cordova app.

## Minimum version requirements

| Braze Plugin | Cordova Android | Cordova iOS |
| ------------ | --------------- | ----------- |
| 10.0.0+      | >= 13.0.0       | >= 5.0.0    |
| 2.31.0+      | >= 12.0.0       | >= 5.0.0    |

This SDK additionally inherits the requirements of its underlying Braze native SDKs. Be sure to also adhere to the lists below:
* [Android SDK requirements](https://github.com/braze-inc/braze-android-sdk?tab=readme-ov-file#version-information)
* [Swift SDK requirements](https://github.com/braze-inc/braze-swift-sdk?tab=readme-ov-file#version-information)

## Installing the SDK
#### ⚠ Only add the Braze Cordova SDK using the methods below. Do not attempt to install using other methods as it could lead to a security breach. ⚠
```
# To use the base SDK functionality, install using the `master` branch.

cordova plugin add https://github.com/braze-inc/braze-cordova-sdk#master

# To use location collection and geofences in addition to the base SDK functionality, install using `geofence-branch`.
cordova plugin add https://github.com/braze-inc/braze-cordova-sdk#geofence-branch
```

## Running the sample application
```
cordova plugin remove cordova-plugin-braze
cordova plugin add https://github.com/braze-inc/braze-cordova-sdk#master

# To run android
cordova run android

# To run iOS
cordova run ios
```
