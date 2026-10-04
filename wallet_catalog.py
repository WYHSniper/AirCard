"""Read local Wallet metadata without treating the Mac cache as a phone inventory."""
from __future__ import annotations

import json
import plistlib
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

CARD_ID = re.compile(r"[-A-Za-z0-9_+=]{20,64}\Z")
SUFFIX = re.compile(r"[A-Za-z0-9]{2,6}\Z")


def decode_archive(data: bytes):
    archive = plistlib.loads(data)
    objects = archive["$objects"]
    if not isinstance(objects, list) or len(objects) > 100000:
        raise ValueError("Invalid archive object table")

    def resolve(value, trail=()):
        if len(trail) > 40:
            raise ValueError("Archive nesting limit")
        if isinstance(value, plistlib.UID):
            index = value.data
            if index in trail or not 0 <= index < len(objects):
                raise ValueError("Invalid archive reference")
            return resolve(objects[index], trail + (index,))
        if isinstance(value, dict):
            if "NS.objects" in value:
                values = [resolve(v, trail) for v in value["NS.objects"]]
                if "NS.keys" in value:
                    return dict(zip([resolve(k, trail) for k in value["NS.keys"]], values))
                return values
            return {k: resolve(v, trail) for k, v in value.items() if not k.startswith("$")}
        if isinstance(value, list):
            return [resolve(v, trail) for v in value]
        return None if value == "$null" else value

    return resolve(archive["$top"]["root"])


def read_limited(path: Path) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("Cache exceeds read limit")
    return data


def clean_suffix(value):
    return value.strip() if isinstance(value, str) and SUFFIX.fullmatch(value.strip()) else None


def added_date(value):
    """Wallet stores the add date as an NSDate (seconds from 2001-01-01 UTC)."""
    seconds = value.get("NS.time") if isinstance(value, dict) else None
    if not isinstance(seconds, (int, float)) or abs(seconds) > 3e10:
        return None
    try:
        return (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=seconds)).date().isoformat()
    except (OverflowError, ValueError):
        return None


def card(identifier, name, source, activation_id=None, suffix=None, suffix_kind=None, device_suffix=None, added_at=None):
    if not isinstance(identifier, str) or not CARD_ID.fullmatch(identifier):
        return None
    result = {"id": identifier, "name": name.strip()[:200] if isinstance(name, str) and name.strip() else "Unnamed card", "source": source}
    if isinstance(activation_id, str) and re.fullmatch(r"[A-Fa-f0-9]{10,64}", activation_id):
        result["activationID"] = activation_id.upper()
    if suffix:
        result["suffix"] = suffix
        result["suffixKind"] = suffix_kind
    # Only read when two rows still look alike: a second, independent ending and
    # the date the card was added. Both are per-card, so one of them separates
    # two cards that share a product name and an account ending.
    if device_suffix and device_suffix != suffix:
        result["deviceSuffix"] = device_suffix
    if added_at:
        result["addedAt"] = added_at
    return result


def unique_cards(rows):
    result = {}
    for row in rows:
        if row is not None:
            result.setdefault(row["id"], row)
    return list(result.values())


def payment_card(data):
    application = data.get("primaryPaymentApplication")
    activation_id = application.get("applicationIdentifier") if isinstance(application, dict) else None
    # Several cards can share one product name ("Platinum Card(R)"), so the
    # account suffix is the only thing that tells those rows apart. It is the
    # real card's last digits; fall back to the device token suffix, which is
    # still stable per card, when Wallet has no account suffix (Apple Cash,
    # transit, ID passes).
    device_suffix = clean_suffix(application.get("DPANSuffix")) if isinstance(application, dict) else None
    suffix, suffix_kind = clean_suffix(data.get("primaryAccountNumberSuffix")), "account"
    if not suffix:
        suffix, suffix_kind = device_suffix, "device"
    return card(data.get("passID"), data.get("displayName") or data.get("organizationName"), "payment",
                activation_id, suffix, suffix_kind, device_suffix, added_date(data.get("ingestedDate")))


def build_catalog(root: Path, confirmed_ids: list[str], product: str) -> dict:
    confirmed = set(confirmed_ids)
    result = {"paymentStatus": "unavailable", "payments": [], "memberships": [], "warnings": [], "cacheUpdatedAt": None}
    archive_path = root / "RemoteDevices.archive"
    try:
        devices = decode_archive(read_limited(archive_path))
        if not isinstance(devices, list):
            raise ValueError("Invalid device list")
        candidates = []
        for device in devices:
            if not isinstance(device, dict) or device.get("modelIdentifier") != product:
                continue
            instruments = device.get("remotePaymentInstruments")
            if not isinstance(instruments, list):
                continue
            rows = unique_cards(payment_card(p)
                                for p in instruments if isinstance(p, dict))
            candidates.append(rows)
        matching = [rows for rows in candidates if confirmed.intersection(p["id"] for p in rows)]
        if len(matching) == 1:
            result["paymentStatus"] = "matched"
            result["payments"] = matching[0]
        elif len(matching) > 1:
            result["paymentStatus"] = "ambiguous"
            result["warnings"].append("More than one cached device matches these cards. Payment names and missing-card counts are withheld.")
        elif len(candidates) == 1:
            result["paymentStatus"] = "matched"
            result["payments"] = candidates[0]
        elif len(candidates) > 1:
            result["paymentStatus"] = "ambiguous"
            result["warnings"].append("More than one cached device has this model. Activate one payment card to identify the correct Wallet cache.")
        else:
            result["paymentStatus"] = "unmatched"
            result["warnings"].append("Scan a payment card on the connected iPhone to match its cache. A missing match can also mean the Mac cache is unavailable or out of date.")
        result["cacheUpdatedAt"] = datetime.fromtimestamp(archive_path.stat().st_mtime, timezone.utc).isoformat()
    except (OSError, ValueError, KeyError, TypeError, IndexError, OverflowError, RecursionError, plistlib.InvalidFileException):
        result["warnings"].append("Payment cache could not be read. Scanning still works; reconnect the iPhone and use Read Cache to retry.")

    try:
        entries = list((root / "Cards").iterdir())
    except OSError:
        entries = []
        result["warnings"].append("Membership cache could not be read. Open membership cards in the iPhone Wallet app and scan them directly.")
    unreadable = False
    for entry in sorted(entries, key=lambda p: p.name):
        if entry.suffix != ".pkpass" or entry.is_symlink() or not CARD_ID.fullmatch(entry.stem):
            continue
        path = entry / "pass.json"
        if path.is_symlink():
            continue
        try:
            data = json.loads(read_limited(path))
            if not isinstance(data, dict):
                raise ValueError("Invalid pass metadata")
            if not any(key in data for key in ("generic", "storeCard", "boardingPass", "eventTicket", "coupon")):
                continue
            labels = [data.get("organizationName"), data.get("description")]
            name = " · ".join(dict.fromkeys(label.strip() for label in labels if isinstance(label, str) and label.strip()))
            row = card(entry.stem, name, "membership")
            if row:
                result["memberships"].append(row)
        except (OSError, ValueError, TypeError):
            unreadable = True
    if unreadable:
        result["warnings"].append("Some membership metadata could not be read. The cache list may be incomplete.")
    result["memberships"] = unique_cards(result["memberships"])
    return result


def main():
    import sys
    request = json.load(sys.stdin)
    ids = request.get("confirmedIDs", [])
    product = request.get("product", "")
    if not isinstance(ids, list) or not all(isinstance(x, str) for x in ids) or not isinstance(product, str):
        raise ValueError("Invalid catalog request")
    print(json.dumps(build_catalog(Path.home() / "Library/Passes", ids, product), ensure_ascii=False))


if __name__ == "__main__":
    main()
