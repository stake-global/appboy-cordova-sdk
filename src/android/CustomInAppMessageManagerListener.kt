package com.appboy.cordova

import android.app.Activity
import com.braze.ui.inappmessage.InAppMessageOperation
import com.braze.ui.inappmessage.listeners.IInAppMessageManagerListener
import android.util.Log
import com.braze.models.inappmessage.IInAppMessage

class CustomInAppMessageManagerListener(activity: Activity) : IInAppMessageManagerListener {
    private val mActivity: Activity
    var inAppDisplayAttempts = 0
    @Override
    fun beforeInAppMessageDisplayed(inAppMessage: IInAppMessage?): InAppMessageOperation {
        return if (inAppDisplayAttempts >= 1) {
            Log.i(
                TAG,
                "Set in-app to display now"
            )
            InAppMessageOperation.DISPLAY_NOW
        } else {
            Log.i(
                TAG,
                "Set in-app to display now"
            )
            InAppMessageOperation.DISPLAY_LATER
        }
    }

    companion object {
        private const val TAG = "BrazeCordova"
    }

    init {
        mActivity = activity
    }
}