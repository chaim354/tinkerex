from app import app


def client():
    app.config.update(TESTING=True)
    return app.test_client()


def test_up():
    r = client().get("/up")
    assert r.status_code == 200
    assert r.data == b"ok"
