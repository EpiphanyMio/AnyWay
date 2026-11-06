package com.locationsimulator.mock;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private TextView status;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        status = new TextView(this);
        status.setTextSize(18);
        layout.addView(status);
        TextView instructions = new TextView(this);
        instructions.setText("开启开发者选项和 USB 调试，在「选择模拟位置信息应用」中选择「定位模拟器」，然后连接 Mac 并在 Mac 应用中刷新设备。停止模拟后请在 Mac 应用中点击「清除定位」。");
        instructions.setPadding(0, padding, 0, padding);
        layout.addView(instructions);
        Button refresh = new Button(this);
        refresh.setText("检查设置");
        refresh.setOnClickListener(view -> updateStatus());
        layout.addView(refresh);
        Button clear = new Button(this);
        clear.setText("清除模拟定位");
        clear.setOnClickListener(view -> {
            try {
                MockLocation.clear(this);
                status.setText("模拟定位已清除");
            } catch (Exception error) {
                status.setText(error.getMessage());
            }
        });
        layout.addView(clear);
        setContentView(layout);
    }

    @Override protected void onResume() {
        super.onResume();
        updateStatus();
    }

    private void updateStatus() {
        status.setText(MockLocation.isSelected(this) ? "已选为模拟位置信息应用" : "尚未选为模拟位置信息应用");
    }
}
