"""HTTP surface: voice tool auth, webhook verification, demo routes."""
import base64
import json
import time

from fastapi.testclient import TestClient
from standardwebhooks.webhooks import Webhook

from app.main import create_app

from .conftest import BASE, HANDLE, outbox_texts


def client(ctx):
    return TestClient(create_app(ctx))


def test_voice_tools_reject_missing_or_wrong_secret(seeded):
    c = client(seeded)
    assert c.get("/voice/tools/fridge").status_code == 401
    assert c.get("/voice/tools/fridge", headers={"X-Tool-Secret": "nope"}).status_code == 401
    assert c.get("/voice/tools/fridge", headers={"X-Tool-Secret": "s3cret"}).status_code == 200


def test_voice_tools_disabled_without_secret(seeded):
    seeded.settings.voice_tool_secret = ""
    assert client(seeded).get("/voice/tools/fridge", headers={"X-Tool-Secret": ""}).status_code == 503


def test_voice_check_and_add(seeded):
    c = client(seeded)
    h = {"X-Tool-Secret": "s3cret"}
    c.post("/demo/mock/text", json={"handle": HANDLE, "text": "hi"})
    r = c.get("/voice/tools/check", params={"item": "eggs"}, headers=h).json()
    assert r["have"] == 0 and "add eggs" in r["text"]
    c.post("/demo/buy?basket=quick")
    r = c.get("/voice/tools/check", params={"item": "eggs"}, headers=h).json()
    assert r["have"] == 1 and r["text"].startswith("Yes, you have eggs")
    r = c.post("/voice/tools/list/add", json={"item": "coffee"}, headers=h).json()
    assert "coffee" in r["text"]
    assert outbox_texts(seeded)[-1].startswith("📞 From your call: 🛒 Added coffee")


def _signed(secret: str, payload: dict, msg_id: str = "msg_1"):
    body = json.dumps(payload)
    ts = str(int(time.time()))
    sig = Webhook(secret).sign(msg_id, __import__("datetime").datetime.fromtimestamp(int(ts),
                               tz=__import__("datetime").timezone.utc), body)
    return body, {"webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": sig,
                  "content-type": "application/json"}


def test_webhook_verifies_and_dedupes(seeded):
    secret = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()
    seeded.settings.photon_webhook_secret = secret
    c = client(seeded)
    message = seeded.photon.inject(HANDLE, "hi", created_at=BASE)
    seeded.photon.inbox.clear()  # deliver only through the webhook
    body, headers = _signed(secret, {"id": "evt_1", "type": "message.received", "data": message})
    bad = dict(headers, **{"webhook-signature": "v1,AAAA"})
    assert c.post("/photon/webhook", content=body, headers=bad).status_code == 400
    with c:
        assert c.post("/photon/webhook", content=body, headers=headers).status_code == 204
        assert c.post("/photon/webhook", content=body, headers=headers).status_code == 204
        for _ in range(50):
            if seeded.photon.outbox:
                break
            time.sleep(0.02)
    assert len(seeded.photon.outbox) == 1 and seeded.photon.outbox[0]["text"].startswith("👋 Hi!")


def test_demo_page_and_state(seeded):
    c = client(seeded)
    assert "DigiFridgy" in c.get("/demo").text
    st = c.get("/demo/state").json()
    assert st["mock_nessie"] and st["household"]["name"] == "Rivera Household"


def test_demo_token(seeded):
    seeded.settings.demo_token = "tok"
    c = client(seeded)
    assert c.post("/demo/sweep").status_code == 401
    assert c.post("/demo/sweep", headers={"x-demo-token": "tok"}).status_code == 200
