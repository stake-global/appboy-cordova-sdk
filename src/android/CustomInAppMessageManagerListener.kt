package com.braze.cordova

import android.app.Activity
import com.braze.ui.inappmessage.InAppMessageOperation
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener
import com.braze.models.inappmessage.IInAppMessage
import com.braze.support.BrazeLogger.brazelog

class CustomInAppMessageManagerListener(activity: Activity) : IInAppMessageManagerListener {
  private var mActivity: Activity = activity
  var inAppDisplayAttempts = 0

  override fun beforeInAppMessageDisplayed(inAppMessage: IInAppMessage): InAppMessageOperation {
    return if (this.inAppDisplayAttempts >= 1) {
      brazelog { "Set in-app to display now"}
      InAppMessageOperation.DISPLAY_NOW
    } else {
      brazelog { "Set in-app to display later"}
      InAppMessageOperation.DISCARD
    }
  }
}