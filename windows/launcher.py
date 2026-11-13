"""Entry point for both the source tree and the PyInstaller executable."""
import asyncio
import json
import sys


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        import anyway.app
        import anyway.android
        import anyway.harmony
        import anyway.ios
        import anyway.iphone_bridge
        print("AnyWay imports OK")
    elif len(sys.argv) > 1 and sys.argv[1] == "--list-devices":
        from pymobiledevice3.usbmux import list_devices
        print(json.dumps([device.serial for device in asyncio.run(list_devices()) if device.is_usb]), flush=True)
    elif len(sys.argv) > 2 and sys.argv[1] == "--iphone-bridge":
        try:
            from anyway.iphone_bridge import run
            asyncio.run(run(sys.argv[2]))
        except Exception as exc:
            print(json.dumps({"ready": False, "error": str(exc)}, ensure_ascii=False), flush=True)
            sys.exit(1)
    else:
        from anyway.app import main
        raise SystemExit(main())

