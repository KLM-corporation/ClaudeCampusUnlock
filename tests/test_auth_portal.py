"""Tests du portail d'authentification (bibliothèque standard uniquement).

Lancer depuis la racine du dépôt :
    python -m unittest discover -s tests -v
"""
import http.client
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import urllib.parse
from hashlib import pbkdf2_hmac
from http.server import ThreadingHTTPServer
from unittest import mock

PORTAL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "auth-portal", "auth_portal.py")
TEST_ITERATIONS = 1000  # les vrais comptes utilisent 600000 ; on accélère les tests
PASSWORD = "correct horse battery staple"

_tmp = tempfile.TemporaryDirectory()
USERS_PATH = os.path.join(_tmp.name, "users.json")


def make_record(password, iterations=TEST_ITERATIONS):
    salt = os.urandom(16)
    return {"salt": salt.hex(), "hash": pbkdf2_hmac("sha256", password.encode(), salt, iterations).hex(), "iterations": iterations}


with open(USERS_PATH, "w", encoding="utf-8") as f:
    json.dump({"gabi": make_record(PASSWORD), "maxim": make_record("autre mot de passe")}, f)
os.environ["USERS_FILE"] = USERS_PATH

_spec = importlib.util.spec_from_file_location("auth_portal", PORTAL_PATH)
ap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ap)
ap._DUMMY_RECORD["iterations"] = TEST_ITERATIONS
ap.AuthGatewayHandler.log_message = lambda *a, **k: None


def reset_state():
    ap.sessions.clear()
    ap.failed_attempts.clear()


class PasswordTests(unittest.TestCase):
    def test_correct_and_wrong_password(self):
        record = make_record(PASSWORD)
        self.assertTrue(ap.verify_password(record, PASSWORD))
        self.assertFalse(ap.verify_password(record, PASSWORD + "x"))

    def test_non_ascii_password(self):
        record = make_record("pässwörd-€-日本")
        self.assertTrue(ap.verify_password(record, "pässwörd-€-日本"))

    def test_malformed_records_are_rejected(self):
        for bad in (None, "texte", [], {}, {"salt": "zz", "hash": "00"}, {"salt": "00", "hash": "00", "iterations": "x"},
                    {"salt": "00", "hash": "00", "iterations": 0}, {"salt": "00", "hash": "00", "iterations": 10**12}):
            self.assertFalse(ap.verify_password(bad, "x"), bad)

    def test_authenticate_is_case_insensitive_and_canonical(self):
        users = {"Gabi": make_record(PASSWORD)}
        self.assertEqual(ap.authenticate(users, "GABI", PASSWORD), "gabi")
        self.assertIsNone(ap.authenticate(users, "gabi", "mauvais"))

    def test_unknown_user_still_pays_the_pbkdf2_cost(self):
        users = {"gabi": make_record(PASSWORD)}
        calls = []
        real = ap.pbkdf2_hmac

        def spy(*args, **kwargs):
            calls.append(args[3])
            return real(*args, **kwargs)

        with mock.patch.object(ap, "pbkdf2_hmac", spy):
            self.assertIsNone(ap.authenticate(users, "inconnu", PASSWORD))
            self.assertEqual(len(calls), 1, "le hash factice doit être calculé pour un identifiant inconnu")
            self.assertIsNone(ap.authenticate(users, "gabi", "mauvais"))
            self.assertEqual(len(calls), 2)

    def test_load_users_rejects_non_object_json(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "u.json")
            with open(p, "w", encoding="utf-8-sig") as f:  # avec BOM, comme PowerShell 5.1
                f.write('["pas", "un", "objet"]')
            with mock.patch.object(ap, "USERS_FILE", p):
                self.assertEqual(ap.load_users(), {})
            with open(p, "w", encoding="utf-8-sig") as f:
                f.write('{"a": {"salt": "00", "hash": "00"}}')
            with mock.patch.object(ap, "USERS_FILE", p):
                self.assertIn("a", ap.load_users())


class RateLimitTests(unittest.TestCase):
    def setUp(self):
        reset_state()

    def test_lock_is_scoped_to_ip_and_username(self):
        for _ in range(ap.RATE_LIMIT_MAX_ATTEMPTS):
            ap.record_failed_attempt("1.1.1.1", "gabi")
        self.assertTrue(ap.is_rate_limited("1.1.1.1", "gabi"))
        self.assertFalse(ap.is_rate_limited("1.1.1.1", "maxim"), "un autre compte ne doit pas être bloqué")
        self.assertFalse(ap.is_rate_limited("2.2.2.2", "gabi"), "une autre IP ne doit pas être bloquée")

    def test_ip_wide_cap_bounds_username_spraying(self):
        for i in range(ap.RATE_LIMIT_IP_MAX):
            ap.record_failed_attempt("3.3.3.3", f"user{i}")
        self.assertTrue(ap.is_rate_limited("3.3.3.3", "gabi"))
        self.assertFalse(ap.is_rate_limited("4.4.4.4", "gabi"))

    def test_success_resets_the_pair_only(self):
        for _ in range(ap.RATE_LIMIT_MAX_ATTEMPTS):
            ap.record_failed_attempt("1.1.1.1", "gabi")
        ap.reset_failed_attempts("1.1.1.1", "gabi")
        self.assertFalse(ap.is_rate_limited("1.1.1.1", "gabi"))

    def test_window_expiry_and_pruning(self):
        start = time.time()
        with mock.patch.object(ap.time, "time", return_value=start):
            for _ in range(ap.RATE_LIMIT_MAX_ATTEMPTS):
                ap.record_failed_attempt("1.1.1.1", "gabi")
            self.assertTrue(ap.is_rate_limited("1.1.1.1", "gabi"))
        with mock.patch.object(ap.time, "time", return_value=start + ap.RATE_LIMIT_WINDOW + 1):
            self.assertFalse(ap.is_rate_limited("1.1.1.1", "gabi"))
            for i in range(1100):  # dépasse le seuil de purge
                ap.record_failed_attempt(f"10.0.{i // 250}.{i % 250}", "x")
            self.assertLess(len(ap.failed_attempts), 2300)
        with mock.patch.object(ap.time, "time", return_value=start + 10 * ap.RATE_LIMIT_WINDOW):
            ap.record_failed_attempt("9.9.9.9", "x")
            self.assertEqual(len([k for k in ap.failed_attempts if k[1] == "9.9.9.9"]), 2)
            self.assertLessEqual(len(ap.failed_attempts), 2)

    def test_sessions_are_purged(self):
        now = time.time()
        ap.sessions["vieille"] = {"user": "gabi", "created_at": now - ap.SESSION_MAX_LIFETIME - 5, "last_seen": now}
        ap.sessions["inactive"] = {"user": "gabi", "created_at": now, "last_seen": now - ap.SESSION_IDLE_TIMEOUT - 5}
        ap.sessions["ok"] = {"user": "gabi", "created_at": now, "last_seen": now}
        ap.purge_expired_sessions()
        self.assertEqual(list(ap.sessions), ["ok"])


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old_timeout = ap.AuthGatewayHandler.timeout
        ap.AuthGatewayHandler.timeout = 1  # pour tester la coupure des connexions muettes
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ap.AuthGatewayHandler)
        cls.server.handle_error = lambda *a: None
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        ap.AuthGatewayHandler.timeout = cls.old_timeout

    def setUp(self):
        reset_state()

    def request(self, method, path, headers=None, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        hdrs = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, hdrs, data

    def login(self, user, password, xff=None):
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if xff:
            headers["X-Forwarded-For"] = xff
        return self.request("POST", "/login", headers, urllib.parse.urlencode({"username": user, "password": password}))

    def raw(self, payload, wait=4.0):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=wait)
        try:
            s.sendall(payload)
            return s.recv(4096)
        except socket.timeout:
            return None
        except ConnectionError:
            return b""
        finally:
            s.close()

    def test_login_flow_cookie_flags_and_verify(self):
        status, headers, _ = self.login("GABI", PASSWORD)
        self.assertEqual((status, headers["location"]), (302, "/portal"))
        cookie_header = headers["set-cookie"]
        for flag in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
            self.assertIn(flag, cookie_header)
        cookie = cookie_header.split(";")[0]
        status, headers, _ = self.request("GET", "/verify", {"Cookie": cookie})
        self.assertEqual((status, headers["x-auth-user"]), (200, "gabi"))
        self.request("GET", "/logout", {"Cookie": cookie})
        status, headers, _ = self.request("GET", "/verify", {"Cookie": cookie})
        self.assertEqual((status, headers["location"]), (302, "/login"))

    def test_verify_without_session_is_a_redirect_for_get_and_head(self):
        for method in ("GET", "HEAD"):
            status, headers, _ = self.request(method, "/verify")
            self.assertEqual((status, headers["location"]), (302, "/login"), method)

    def test_head_matches_get_headers_without_body(self):
        s_get, h_get, body = self.request("GET", "/login")
        s_head, h_head, head_body = self.request("HEAD", "/login")
        self.assertEqual((s_get, s_head), (200, 200))
        self.assertEqual(h_get["content-length"], h_head["content-length"])
        self.assertEqual(head_body, b"")
        self.assertGreater(len(body), 0)

    def test_head_logout_does_not_revoke_the_session(self):
        _, headers, _ = self.login("gabi", PASSWORD)
        cookie = headers["set-cookie"].split(";")[0]
        self.request("HEAD", "/logout", {"Cookie": cookie})
        status, _, _ = self.request("GET", "/verify", {"Cookie": cookie})
        self.assertEqual(status, 200)

    def test_security_headers_on_pages(self):
        _, headers, _ = self.request("GET", "/login")
        self.assertIn("frame-ancestors 'self'", headers["content-security-policy"])
        self.assertEqual(headers["x-frame-options"], "SAMEORIGIN")
        self.assertEqual(headers["x-content-type-options"], "nosniff")
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(headers["server"], "auth-portal")

    def test_wrong_password_redirects_and_unknown_user_looks_identical(self):
        r1 = self.login("gabi", "mauvais")
        r2 = self.login("personne", "mauvais")
        self.assertEqual((r1[0], r1[1]["location"]), (302, "/login?error=invalid"))
        self.assertEqual((r2[0], r2[1]["location"]), (302, "/login?error=invalid"))

    def test_rate_limit_locks_only_the_attacked_account(self):
        for i in range(ap.RATE_LIMIT_MAX_ATTEMPTS):
            self.login("gabi", f"mauvais{i}", xff="198.51.100.9")
        _, headers, _ = self.login("gabi", PASSWORD, xff="198.51.100.9")
        self.assertEqual(headers["location"], "/login?error=rate_limited")
        # le même client (même IP vue par le portail) peut encore se connecter sur un autre compte
        _, headers, _ = self.login("maxim", "autre mot de passe", xff="198.51.100.9")
        self.assertEqual(headers["location"], "/portal")

    def test_client_ip_uses_last_forwarded_entry_and_ignores_garbage(self):
        self.login("gabi", "mauvais", xff="6.6.6.6, 203.0.113.5")
        self.assertIn(("ip", "203.0.113.5"), ap.failed_attempts)
        self.assertNotIn(("ip", "6.6.6.6"), ap.failed_attempts)
        reset_state()
        self.login("gabi", "mauvais", xff="pas-une-ip")
        self.assertIn(("ip", "127.0.0.1"), ap.failed_attempts)

    def test_invalid_content_length_is_rejected(self):
        head = b"POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: %s\r\n\r\n"
        self.assertTrue(self.raw(head % b"abc").startswith(b"HTTP/1.0 400"))
        self.assertTrue(self.raw(head % b"-1").startswith(b"HTTP/1.0 400"))
        self.assertTrue(self.raw(head % b"1000000").startswith(b"HTTP/1.0 413"))
        self.assertTrue(self.raw(head % (b"9" * 400)).startswith(b"HTTP/1.0 413"))

    def test_silent_body_is_cut_by_the_timeout(self):
        started = time.time()
        answer = self.raw(b"POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nusername=g")
        self.assertEqual(answer, b"", "la connexion doit être fermée sans réponse")
        self.assertLess(time.time() - started, 4)

    def test_unknown_paths_and_methods(self):
        self.assertEqual(self.request("GET", "/nope")[0], 404)
        self.assertEqual(self.request("POST", "/nope", body=b"x")[0], 404)
        self.assertEqual(self.request("PUT", "/login")[0], 501)


if __name__ == "__main__":
    unittest.main()
