// // TODO: Joel: this needs to be converted over to .kt and integrated

package com.braze.cordova

import android.app.Activity;
import com.braze.ui.inappmessage.InAppMessageOperation;
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener;
import android.util.Log;
import com.braze.models.inappmessage.IInAppMessage;

class CustomInAppMessageManagerListener : IInAppMessageManagerListener {
  private var Activity mActivity;
  public var inAppDisplayAttempts = 0;
//   private static final String TAG = "BrazeCordova";

  override fun CustomInAppMessageManagerListener(activity: Activity) {
    mActivity = activity;
  }

  override fun beforeInAppMessageDisplayed(inAppMessageBase: IInAppMessage): InAppMessageOperation {
    if (this.inAppDisplayAttempts >= 1) {
      brazelog(I) { "Set in-app to display now"}
      return InAppMessageOperation.DISPLAY_NOW;
    } else {
      brazelog(I) { "Set in-app to display later"}
      return InAppMessageOperation.DISPLAY_LATER;
    }
  }
}