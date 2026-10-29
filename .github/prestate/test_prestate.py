"""Exercise the real CLI gates, including bad inputs that must fail CI."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
STOCK = "0x031ac6f15c19010da258f5cb633ef6ca9318c2d0f244bea6b2045ce6b790e1df"
CUSTOM = "0x" + "ab" * 32


class PrestateGates(unittest.TestCase):
    def gate(self, gate, pre=CUSTOM, **inputs):
        with tempfile.TemporaryDirectory() as tmp:
            proof = Path(tmp) / "proof.json"
            proof.write_text(json.dumps({"pre": pre}))
            cmd = ["python3", str(HERE / "check-prestate.py"), gate, "--proof", str(proof)]
            for name, value in inputs.items():
                path = Path(tmp) / f"{name}.json"
                path.write_text(json.dumps(value))
                cmd += [f"--{name}", str(path)]
            return subprocess.run(cmd, capture_output=True, text=True)

    def test_witness(self):
        self.assertEqual(self.gate("witness", witness={"witnessHash": CUSTOM, "stateVersion": 8}).returncode, 0)
        for witness in (
            {"witnessHash": STOCK, "stateVersion": 8},
            {"witnessHash": CUSTOM, "stateVersion": 9},
            {"witnessHash": CUSTOM, "stateVersion": "8"},
            {"witnessHash": CUSTOM},
        ):
            with self.subTest(witness=witness):
                self.assertNotEqual(self.gate("witness", witness=witness).returncode, 0)

    def test_stock(self):
        self.assertEqual(self.gate("stock", pre=STOCK).returncode, 0)
        for pre in (CUSTOM, None, "not-a-hash"):
            with self.subTest(pre=pre):
                self.assertNotEqual(self.gate("stock", pre=pre).returncode, 0)

    def test_distinct(self):
        self.assertEqual(self.gate("distinct", stock={"pre": STOCK}).returncode, 0)
        self.assertNotEqual(self.gate("distinct", stock={"pre": CUSTOM}).returncode, 0)
        self.assertNotEqual(self.gate("distinct", stock={}).returncode, 0)

    def test_interop_is_additive(self):
        with tempfile.TemporaryDirectory() as tmp:
            default, interop = Path(tmp) / "default", Path(tmp) / "interop"
            for path, flags in ((default, []), (interop, ["--interop"])):
                subprocess.run(["python3", str(HERE / "gen-kona-custom-configs.py"),
                                "--rollup", str(ROOT / "deployments/sepolia/rollup.json"),
                                "--out", str(path), *flags], check=True, capture_output=True)
            self.assertEqual(sorted(p.name for p in default.iterdir()), ["chainList.json", "configs.json"])
            for name in ("chainList.json", "configs.json"):
                self.assertEqual((default / name).read_bytes(), (interop / name).read_bytes())
            self.assertEqual(json.loads((interop / "depsets.json").read_text()), [{
                "dependencies": {"852": {}}, "overrideMessageExpiryWindow": None,
            }])


if __name__ == "__main__":
    unittest.main()
