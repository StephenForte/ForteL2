package derivation

import (
	"strings"
	"testing"
)

func TestRequireSealingELBin(t *testing.T) {
	if err := requireSealingELBin("/opt/bin/op-geth"); err != nil {
		t.Fatal(err)
	}
	if err := requireSealingELBin("op-geth"); err != nil {
		t.Fatal(err)
	}
	err := requireSealingELBin("/tmp/evil.sh")
	if err == nil || !strings.Contains(err.Error(), "basename must be op-geth") {
		t.Fatalf("want basename refusal, got %v", err)
	}
	if err := runCmd("init", "/bin/echo", "hi"); err == nil {
		t.Fatal("runCmd must refuse a non-op-geth binary")
	}
	if _, err := startCmd("/usr/bin/true"); err == nil {
		t.Fatal("startCmd must refuse a non-op-geth binary")
	}
}
