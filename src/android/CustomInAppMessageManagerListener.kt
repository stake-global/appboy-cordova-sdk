// // TODO: Joel: this needs to be converted over to .kt and integrated

package com.braze.cordova

import com.braze.ui.inappmessage.InAppMessageOperation
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener
import androidx.appcompat.app.AppCompatActivity
import com.braze.models.inappmessage.IInAppMessage
import com.braze.support.BrazeLogger.brazelog

class CustomInAppMessageManagerListener(activity: AppCompatActivity) : IInAppMessageManagerListener {

  var mActivity = activity
  public var inAppDisplayAttempts = 0
//   private static final String TAG = "BrazeCordova";

//   fun CustomInAppMessageManagerListener(activity: Activity) {
//     var mActivity = activity
//  }

  override fun beforeInAppMessageDisplayed(inAppMessageBase: IInAppMessage): InAppMessageOperation {
    return if (this.inAppDisplayAttempts >= 1) {
      brazelog { "Set in-app to display now"}
      InAppMessageOperation.DISPLAY_NOW
    } else {
      brazelog { "Set in-app to display later"}
      InAppMessageOperation.DISPLAY_LATER
    }
  }
}