// TODO: Joel: this needs to be converted over to .kt and integrated - file set up named CustomInAppMessageManagerListener.kt

package com.appboy.cordova;

import android.app.Activity;
import com.braze.ui.inappmessage.InAppMessageOperation;
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener;
import android.util.Log;
import com.braze.models.inappmessage.IInAppMessage;


public class CustomInAppMessageManagerListener implements IInAppMessageManagerListener {
  private final Activity mActivity;
  public int inAppDisplayAttempts = 0;
  private static final String TAG = "BrazeCordova";

  public CustomInAppMessageManagerListener(Activity activity) {
    mActivity = activity;
  }

  @Override
  public InAppMessageOperation beforeInAppMessageDisplayed(IInAppMessage inAppMessage) {
    if (this.inAppDisplayAttempts >= 1) {
      Log.i(TAG, "Set in-app to display now");
      return InAppMessageOperation.DISPLAY_NOW;
    } else {
      Log.i(TAG, "Set in-app to display now");
      return InAppMessageOperation.DISPLAY_LATER;
    }
  }


}