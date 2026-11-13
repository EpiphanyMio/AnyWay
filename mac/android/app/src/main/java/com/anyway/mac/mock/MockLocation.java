package com.anyway.mac.mock;

import android.app.AppOpsManager;
import android.content.Context;
import android.location.Location;
import android.location.LocationManager;
import android.os.Process;
import android.os.SystemClock;

final class MockLocation {
    private MockLocation() {}

    static boolean isSelected(Context context) {
        AppOpsManager appOps = (AppOpsManager) context.getSystemService(Context.APP_OPS_SERVICE);
        return appOps != null && appOps.checkOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION,
                Process.myUid(), context.getPackageName()) == AppOpsManager.MODE_ALLOWED;
    }

    static void set(Context context, double latitude, double longitude) {
        if (!Double.isFinite(latitude) || !Double.isFinite(longitude)
                || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
            throw new IllegalArgumentException("无效的经纬度");
        }
        if (!isSelected(context)) {
            throw new SecurityException("请在 Android 开发者选项中选择「AnyWay」作为模拟位置信息应用");
        }
        LocationManager manager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        if (manager == null) throw new IllegalStateException("定位服务不可用");
        Location location = new Location(LocationManager.GPS_PROVIDER);
        location.setLatitude(latitude);
        location.setLongitude(longitude);
        location.setAccuracy(3f);
        location.setTime(System.currentTimeMillis());
        location.setElapsedRealtimeNanos(SystemClock.elapsedRealtimeNanos());
        try {
            manager.setTestProviderLocation(LocationManager.GPS_PROVIDER, location);
        } catch (IllegalArgumentException missingProvider) {
            manager.addTestProvider(LocationManager.GPS_PROVIDER, false, false, false,
                    false, true, true, true, 1, 1);
            manager.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true);
            manager.setTestProviderLocation(LocationManager.GPS_PROVIDER, location);
        }
    }

    static void clear(Context context) {
        LocationManager manager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
        if (manager == null) throw new IllegalStateException("定位服务不可用");
        try {
            manager.removeTestProvider(LocationManager.GPS_PROVIDER);
        } catch (IllegalArgumentException ignored) {
            // Already cleared.
        }
    }
}
