"""Location search and school-campus result ordering for the Windows client."""
from __future__ import annotations

import json
import math
import re
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .core import Coordinate

USER_AGENT = "AnyWay/0.1 (desktop location testing app)"


def search_places(query: str) -> list[dict]:
    query = query.strip()
    if query.startswith("浙大"):
        query = "浙江大学" + query[2:]
    if query.startswith("北邮"):
        query = "北京邮电大学" + query[2:]
    if "".join(query.split()).replace("（", "").replace("）", "") == "北京邮电大学沙河校区":
        return [{"name": "北京邮电大学（沙河校区）", "subtitle": "OpenStreetMap way 685054417",
                 "point": Coordinate(40.15608, 116.28333), "school": True}]
    places = _nominatim_places(query, limit=40 if any(
        term in query for term in ("大学", "学院", "学校", "中学", "小学")) else 8)
    if any(term in query for term in ("校区", "分校")):
        return places
    school = next((place for place in places if place["school"]
                   and _school_name(place["name"]) == _school_name(query)), None)
    if school is None:
        school = next((place for place in places if place["school"]), None)
    if school is None:
        return places
    root = _school_name(query)
    campuses = [place for place in places if _is_campus(place["name"], root)]
    try:
        campuses.extend(_overpass_campuses(root, school["point"]))
    except (OSError, ValueError, KeyError):
        pass  # The original school result remains available when Overpass is unreachable.
    if root == "北京邮电大学":
        campuses.append({"name": "北京邮电大学（沙河校区）", "subtitle": "OpenStreetMap way 685054417",
                         "point": Coordinate(40.15608, 116.28333), "school": True})
    unique = []
    for campus in campuses:
        if (campus["point"].distance(school["point"]) >= 80
                and not any(campus["point"].distance(other["point"]) < 80 for other in unique)):
            campus["school"] = True
            unique.append(campus)
    remaining = [place for place in places if place is not school and not any(
        place["point"].distance(campus["point"]) < 80 for campus in unique)]
    return [school] + unique + remaining[:8]


def _school_name(name: str) -> str:
    return "".join(char for char in name.casefold() if not char.isspace() and char not in "（）()·-")


def _is_campus(name: str, school_name: str) -> bool:
    root, candidate = _school_name(school_name), _school_name(name)
    if not candidate.startswith(root) or candidate == root:
        return False
    suffix = candidate[len(root):]
    return any(term in suffix for term in ("校区", "分校", "校本部"))


def _nominatim_places(query: str, limit: int = 8) -> list[dict]:
    url = "https://nominatim.openstreetmap.org/search?" + urlencode({
        "q": query, "format": "jsonv2", "limit": limit, "accept-language": "zh-CN"})
    with urlopen(Request(url, headers={"User-Agent": USER_AGENT}), timeout=15) as response:
        records = json.load(response)
    places = []
    for item in records:
        point = Coordinate(float(item["lat"]), float(item["lon"]))
        name = item.get("name") or item.get("display_name", "未命名地点").split(",")[0]
        category = item.get("category", "")
        school = category == "amenity" and item.get("type") in ("school", "university", "college")
        places.append({"name": name, "subtitle": item.get("display_name", ""),
                       "point": point, "school": school})
    return places


def _overpass_campuses(root: str, center: Coordinate) -> list[dict]:
    if len(root) < 4 or len(root) > 60:
        return []
    lon_span = min(2, 0.8 / max(0.2, math.cos(math.radians(center.latitude))))
    bbox = (f"{center.latitude - .8:.5f},{center.longitude - lon_span:.5f},"
            f"{center.latitude + .8:.5f},{center.longitude + lon_span:.5f}")
    pattern = json.dumps("^" + re.escape(root) + ".*(校区|分校)", ensure_ascii=False)
    query = f'[out:json][timeout:20];nwr["name"~{pattern}]({bbox});out center 80;'
    with urlopen(Request("https://overpass-api.de/api/interpreter", data=query.encode(),
                         headers={"User-Agent": USER_AGENT}), timeout=25) as response:
        records = json.load(response)["elements"]
    campuses = []
    for item in records:
        name = item.get("tags", {}).get("name", "")
        point_data = item.get("center", item)
        if not _is_campus(name, root) or "lat" not in point_data or "lon" not in point_data:
            continue
        campuses.append({"name": name, "subtitle": "校区 · OpenStreetMap",
                         "point": Coordinate(float(point_data["lat"]), float(point_data["lon"])),
                         "school": True})
    return campuses


def nearby_sports(school: Coordinate) -> list[dict]:
    # One bounded query rather than repeated searches; executed only for a selected school.
    query = f'[out:json][timeout:20];(nwr(around:3000,{school.latitude},{school.longitude})[leisure~"^(pitch|sports_centre|stadium|track|fitness_centre|swimming_pool)$"];nwr(around:3000,{school.latitude},{school.longitude})[sport~"^(basketball|soccer|tennis|badminton|swimming|running)$"];);out center 40;'
    with urlopen(Request("https://overpass-api.de/api/interpreter", data=query.encode(),
                         headers={"User-Agent": USER_AGENT}), timeout=30) as response:
        records = json.load(response)["elements"]
    found = []
    for item in records:
        tags = item.get("tags", {})
        center = item.get("center", item)
        if "lat" not in center or "lon" not in center:
            continue
        point = Coordinate(float(center["lat"]), float(center["lon"]))
        if point.distance(school) > 3000:
            continue
        name = tags.get("name:zh") or tags.get("name") or tags.get("sport") or tags.get("leisure", "运动场")
        if any(p["name"] == name and p["point"].distance(point) < 80 for p in found):
            continue
        found.append({"name": name, "subtitle": f"距离 {point.distance(school):.0f} 米 · OpenStreetMap",
                      "point": point, "school": False})
    return sorted(found, key=lambda p: p["point"].distance(school))[:30]


