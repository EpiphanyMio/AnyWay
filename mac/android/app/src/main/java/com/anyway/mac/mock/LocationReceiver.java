package com.anyway.mac.mock;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;

public final class LocationReceiver extends BroadcastReceiver {
    private static PowerManager.WakeLock routeWakeLock;

    @Override public void onReceive(Context context, Intent intent) {
        try {
            String action = intent.getStringExtra("action");
            if ("set".equals(action)) {
                double latitude = Double.parseDouble(intent.getStringExtra("latitude"));
                double longitude = Double.parseDouble(intent.getStringExtra("longitude"));
                MockLocation.set(context, latitude, longitude);
            } else if ("clear".equals(action)) {
                MockLocation.clear(context);
            } else if ("keep-awake".equals(action)) {
                if (routeWakeLock == null) {
                    PowerManager power = context.getSystemService(PowerManager.class);
                    if (power == null) throw new IllegalStateException("Android 电源服务不可用");
                    routeWakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AnyWay:RouteSimulation");
                    routeWakeLock.setReferenceCounted(false);
                }
                routeWakeLock.acquire(30_000);
            } else if ("allow-sleep".equals(action)) {
                if (routeWakeLock != null && routeWakeLock.isHeld()) routeWakeLock.release();
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
