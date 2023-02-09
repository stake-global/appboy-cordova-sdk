package com.appboy.cordova;

import android.app.Activity;
import android.view.View;
import android.widget.Toast;

import com.braze.models.inappmessage.IInAppMessage;
import com.braze.models.inappmessage.MessageButton;
import com.braze.ui.inappmessage.InAppMessageCloser;
import com.braze.ui.inappmessage.InAppMessageOperation;
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener;

import java.util.Map;

public class CustomInAppMessageManagerListener implements IInAppMessageManagerListener {
  private final Activity mActivity;
  private Double inAppDisplayAttempts = 0;

  public CustomInAppMessageManagerListener(Activity activity) {
    mActivity = activity;
  }

  @Override
  private InAppMessageOperation beforeInAppMessageDisplayed(inAppMessage IInAppMessage) {
    if (this.inAppDisplayAttempts >= 1) {
      Log.i("Set in-app to display now");
      return InAppMessageOperation.DISPLAY_NOW;
    } else {
      Log.i("Set in-app to display now");
      return InAppMessageOperation.DISPLAY_LATER;
    }
  }
}