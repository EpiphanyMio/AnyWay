"""Persistent iOS 17+ developer location session. One JSON request per line."""

import asyncio
import json
import sys
from contextlib import AsyncExitStack, asynccontextmanager

from pymobiledevice3.exceptions import ConnectionTerminatedError
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from iphone_wireless import device_inventory, ip_tunnel, location_tunnel, prepare_wireless


def reply(**values):
    print(json.dumps(values, ensure_ascii=False), flush=True)


@asynccontextmanager
async def location_service(device):
    async with AsyncExitStack() as services:
        try:
            dvt = await services.enter_async_context(DvtProvider(device))
            location = await services.enter_async_context(LocationSimulation(dvt))
        except (ConnectionTerminatedError, OSError, asyncio.IncompleteReadError) as exc:
            raise RuntimeError("已验证 iPhone 并建立隧道，但开发者定位服务断开。请解锁手机，确认开发者模式和开发者组件已就绪后再试。") from exc
        yield location


async def _check_ip(address, udid):
    async with ip_tunnel(address, udid) as device:
        async with location_service(device):
            return device.udid


async def check_ip(address, udid=None):
    try:
        return await asyncio.wait_for(_check_ip(address, udid), 20)
    except asyncio.TimeoutError as exc:
        raise RuntimeError("打开 iPhone 定位服务超时，请解锁手机并检查开发者模式。") from exc


async def run(udid, address=None):
    async with location_tunnel(udid, address) as device:
        async with location_service(device) as location:
            reply(ready=True)
            while True:
                line = await asyncio.to_thread(sys.stdin.readline)
                if not line:
                    await location.clear()
                    return
                try:
                    request = json.loads(line)
                    if request.get("action") == "set":
                        await location.set(float(request["latitude"]), float(request["longitude"]))
                        reply(ok=True)
                    elif request.get("action") == "clear":
                        await location.clear()
                        reply(ok=True)
                    else:
                        reply(ok=False, error="未知定位命令")
                except Exception as error:
                    reply(ok=False, error=str(error))


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--list-devices":
            reply(**asyncio.run(device_inventory()))
        elif sys.argv[1] == "--check-ip":
            reply(udid=asyncio.run(check_ip(*sys.argv[2:])))
        elif sys.argv[1] == "--prepare-wireless":
            asyncio.run(prepare_wireless(sys.argv[2]))
            reply(ok=True)
        else:
            asyncio.run(run(*sys.argv[1:]))
    except Exception as error:
        reply(ready=False, error=str(error))
        sys.exit(1)
