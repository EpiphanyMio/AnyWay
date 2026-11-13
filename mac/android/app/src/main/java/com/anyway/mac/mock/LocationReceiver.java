package com.anyway.mac.mock;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class LocationReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        try {
            String action = intent.getStringExtra("action");
            if ("set".equals(action)) {
                double latitude = Double.parseDouble(intent.getStringExtra("latitude"));
                double longitude = Double.parseDouble(intent.getStringExtra("longitude"));
                MockLocation.set(context, latitude, longitude);
            } else if ("clear".equals(action)) {
                MockLocation.clear(context);
            } else {
                throw new IllegalArgumentException("未知定位命令");
            }
            setResultCode(1);
        } catch (Exception error) {
            setResultCode(2);
            setResultData(error.getMessage() == null ? error.toString() : error.getMessage());
        }
    }
}
