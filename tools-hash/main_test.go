package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// goldenDigest is the toolsHash of the fixture built by buildGoldenFixture.
//
// This constant was NOT produced by running the code under test. It was
// produced by an independent Python implementation written directly from the
// prose specification, and separately confirmed by hand-assembling the byte
// stream with printf(1) and piping it through sha256sum. Regenerating it from
// ToolsHash would make this test assert only that the code does what it does.
const goldenDigest = "859040066f32871952f9eb5130c603d1163d6d04dc2249b9b5785dd98664b888"

// --- fixture construction -------------------------------------------------

// node is one node in a fixture tree. Exactly one of content/linkTarget is
// meaningful; link is set for symlinks.
type node struct {
	path       string // slash-separated, relative to the repo root
	content    string
	mode       os.FileMode
	link       bool
	linkTarget string
}

// goldenFixture is the golden vector's tree, in creation order.
//
// It deliberately contains:
//   - tools/Makefile      an uppercase name, to catch case-insensitive sorting
//     ('M' 0x4D sorts before 'a' 0x61 byte-wise)
//   - tools/a.c + tools/a/  a file and a directory whose names collide, to catch
//     per-directory walk order being used instead of a global
//     byte-wise sort ('.' 0x2E sorts before '/' 0x2F, so
//     tools/a.c must come before tools/a/nested.c)
//   - tools/preproc/build.sh   an executable regular file
//   - tools/link          a symlink
//   - tools/agbcc/**      excluded content, including a nested directory
//   - README.md, src/     files outside tools/, which must be ignored
var goldenFixture = []node{
	{path: "tools/Makefile", content: "include ../make_tools.mk\n", mode: 0o644},
	{path: "tools/a.c", content: "a\n", mode: 0o644},
	{path: "tools/a/nested.c", content: "nested\n", mode: 0o644},
	{path: "tools/preproc/preproc.c", content: "int main(void) { return 0; }\n", mode: 0o644},
	{path: "tools/preproc/build.sh", content: "#!/bin/sh\nmake\n", mode: 0o755},
	{path: "tools/agbcc/agbcc", content: "binary\n", mode: 0o755},
	{path: "tools/agbcc/lib/libc.a", content: "lib\n", mode: 0o644},
	{path: "README.md", content: "# rotomlab\n", mode: 0o644},
	{path: "src/main.c", content: "void main(void) {}\n", mode: 0o644},
	{path: "tools/link", link: true, linkTarget: "preproc/preproc.c"},
}

// buildTree materialises nodes under a fresh temp directory and returns its
// path. Modes are set explicitly with Chmod because os.WriteFile's permission
// argument is masked by the process umask, which would otherwise make the
// digest depend on the environment running the test.
func buildTree(t *testing.T, nodes []node) string {
	t.Helper()
	root := t.TempDir()
	for _, e := range nodes {
		abs := filepath.Join(root, filepath.FromSlash(e.path))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatalf("mkdir for %s: %v", e.path, err)
		}
		if e.link {
			if err := os.Symlink(filepath.FromSlash(e.linkTarget), abs); err != nil {
				t.Fatalf("symlink %s: %v", e.path, err)
			}
			continue
		}
		if err := os.WriteFile(abs, []byte(e.content), 0o644); err != nil {
			t.Fatalf("write %s: %v", e.path, err)
		}
		if err := os.Chmod(abs, e.mode); err != nil {
			t.Fatalf("chmod %s: %v", e.path, err)
		}
	}
	return root
}

func buildGoldenFixture(t *testing.T) string {
	t.Helper()
	return buildTree(t, goldenFixture)
}

func mustHash(t *testing.T, root string) string {
	t.Helper()
	got, err := ToolsHash(root)
	if err != nil {
		t.Fatalf("ToolsHash(%s): %v", root, err)
	}
	return got
}

// streamDigest is an in-test oracle: it hashes an explicitly ordered list of
// (path, exec, payload) triples per the spec, so a test can state the expected
// node order in the source rather than trusting the walker's.
func streamDigest(triples [][3]string) string {
	h := sha256.New()
	for _, tr := range triples {
		h.Write([]byte(tr[0]))
		h.Write([]byte{0})
		h.Write([]byte(tr[1]))
		h.Write([]byte{0})
		h.Write([]byte(tr[2]))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// --- tests ----------------------------------------------------------------

func TestGoldenVector(t *testing.T) {
	got := mustHash(t, buildGoldenFixture(t))
	if got != goldenDigest {
		t.Errorf("digest changed\n got %s\nwant %s", got, goldenDigest)
	}
}

// TestGoldenVectorEntryOrder states the expected stream explicitly, so a
// failure says which nodes are involved rather than only that a hex constant
// moved.
func TestGoldenVectorEntryOrder(t *testing.T) {
	want := streamDigest([][3]string{
		{"tools/Makefile", "0", "include ../make_tools.mk\n"},
		{"tools/a.c", "0", "a\n"},
		{"tools/a/nested.c", "0", "nested\n"},
		{"tools/link", "0", "preproc/preproc.c"},
		{"tools/preproc/build.sh", "1", "#!/bin/sh\nmake\n"},
		{"tools/preproc/preproc.c", "0", "int main(void) { return 0; }\n"},
	})
	if want != goldenDigest {
		t.Fatalf("in-test oracle disagrees with the golden constant: %s vs %s", want, goldenDigest)
	}
	if got := mustHash(t, buildGoldenFixture(t)); got != want {
		t.Errorf("stream mismatch\n got %s\nwant %s", got, want)
	}
}

func TestAgbccIsExcluded(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)

	if err := os.MkdirAll(filepath.Join(root, "tools", "agbcc", "deep", "deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{
		"tools/agbcc/newfile.c",
		"tools/agbcc/deep/deeper/x.h",
	} {
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(p)), []byte("new\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if after := mustHash(t, root); after != before {
		t.Errorf("adding files under tools/agbcc changed the digest: %s -> %s", before, after)
	}
}

// TestAgbccExclusionIsExactPath guards the exclusion against being a prefix or
// substring match: tools/agbcc-notes and tools/nested/agbcc are ordinary content.
func TestAgbccExclusionIsExactPath(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)

	if err := os.MkdirAll(filepath.Join(root, "tools", "nested", "agbcc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tools", "nested", "agbcc", "x.c"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after == before {
		t.Error("tools/nested/agbcc was excluded; only the top-level tools/agbcc should be")
	}

	root2 := buildGoldenFixture(t)
	if err := os.WriteFile(filepath.Join(root2, "tools", "agbcc-notes.md"), []byte("notes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root2); after == before {
		t.Error("tools/agbcc-notes.md was excluded; the exclusion must match the whole path component")
	}
}

func TestExecBitMatters(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)

	if err := os.Chmod(filepath.Join(root, "tools", "a.c"), 0o755); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after == before {
		t.Error("chmod +x on tools/a.c did not change the digest")
	}
}

func TestContentMatters(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)

	if err := os.WriteFile(filepath.Join(root, "tools", "a.c"), []byte("b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after == before {
		t.Error("changing one byte of tools/a.c did not change the digest")
	}
}

func TestPathMatters(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)

	if err := os.Rename(
		filepath.Join(root, "tools", "a.c"),
		filepath.Join(root, "tools", "b.c"),
	); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after == before {
		t.Error("renaming tools/a.c to tools/b.c did not change the digest")
	}
}

// TestOrderingIsIndependentOfCreationOrder builds the same logical tree twice
// with nodes created in opposite orders. On most Linux filesystems readdir
// returns nodes roughly in creation order, so a walker that trusted readdir
// rather than sorting would produce two different digests here.
func TestOrderingIsIndependentOfCreationOrder(t *testing.T) {
	forward := buildTree(t, goldenFixture)

	reversed := make([]node, 0, len(goldenFixture))
	for i := len(goldenFixture) - 1; i >= 0; i-- {
		reversed = append(reversed, goldenFixture[i])
	}
	backward := buildTree(t, reversed)

	a, b := mustHash(t, forward), mustHash(t, backward)
	if a != b {
		t.Errorf("digest depends on filesystem walk order: %s vs %s", a, b)
	}
	if a != goldenDigest {
		t.Errorf("digest %s does not match the golden vector %s", a, goldenDigest)
	}
}

// TestSymlinksAreNotFollowed pins both halves of the symlink rule: the digest
// covers the short target string, and the target file's content is irrelevant.
func TestSymlinksAreNotFollowed(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "payload"), 0o755); err != nil {
		t.Fatal(err)
	}

	big := filepath.Join(root, "payload", "big.bin")
	if err := os.WriteFile(big, []byte(strings.Repeat("A", 1<<20)), 0o644); err != nil {
		t.Fatal(err)
	}
	target := filepath.FromSlash("../payload/big.bin")
	if err := os.Symlink(target, filepath.Join(root, "tools", "lnk")); err != nil {
		t.Fatal(err)
	}

	want := streamDigest([][3]string{{"tools/lnk", "0", "../payload/big.bin"}})
	got := mustHash(t, root)
	if got != want {
		t.Errorf("symlink not hashed as its target string\n got %s\nwant %s", got, want)
	}

	// Rewriting the target with different content of a different length must
	// not move the digest.
	if err := os.WriteFile(big, []byte(strings.Repeat("B", 1<<21)), 0o644); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after != got {
		t.Errorf("changing the symlink target's content changed the digest: %s -> %s", got, after)
	}
}

// TestSymlinkExecBitIsAlwaysZero: a symlink's own mode bits are 0777 on Linux
// and unspecified elsewhere, so they must not reach the stream.
func TestSymlinkExecBitIsAlwaysZero(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere", filepath.Join(root, "tools", "lnk")); err != nil {
		t.Fatal(err)
	}
	want := streamDigest([][3]string{{"tools/lnk", "0", "elsewhere"}})
	if got := mustHash(t, root); got != want {
		t.Errorf("symlink exec byte is not '0'\n got %s\nwant %s", got, want)
	}
}

// TestSymlinkedDirectoryIsNotDescendedInto: a symlink to a directory is an
// node like any other, hashed as its target string.
func TestSymlinkedDirectoryIsNotDescendedInto(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "outside", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "outside", "sub", "secret.c"), []byte("secret\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.FromSlash("../outside"), filepath.Join(root, "tools", "d")); err != nil {
		t.Fatal(err)
	}
	want := streamDigest([][3]string{{"tools/d", "0", "../outside"}})
	if got := mustHash(t, root); got != want {
		t.Errorf("symlinked directory was descended into\n got %s\nwant %s", got, want)
	}
}

// TestEmptyDirectoriesAreInvisible documents an accepted consequence of "for
// each file": directories are not nodes, so an empty one cannot be
// represented. Git cannot represent one either, so a pristine clone never has
// one, and hashing them would make a git checkout and a tarball copy of the
// same tree disagree.
func TestEmptyDirectoriesAreInvisible(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)
	if err := os.MkdirAll(filepath.Join(root, "tools", "empty", "alsoempty"), 0o755); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after != before {
		t.Errorf("an empty directory changed the digest: %s -> %s", before, after)
	}
}

// TestOnlyToolsIsHashed: content elsewhere in the repository is irrelevant.
func TestOnlyToolsIsHashed(t *testing.T) {
	root := buildGoldenFixture(t)
	before := mustHash(t, root)
	if err := os.WriteFile(filepath.Join(root, "src", "other.c"), []byte("other\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Makefile"), []byte("all:\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if after := mustHash(t, root); after != before {
		t.Errorf("content outside tools/ changed the digest: %s -> %s", before, after)
	}
}

// TestIrregularEntryIsAnError: skipping silently is how a hash that is supposed
// to detect modification learns to ignore things. A unix socket is used because
// net.Listen creates one with nothing but the standard library, and it needs no
// build tags.
func TestIrregularEntryIsAnError(t *testing.T) {
	root := buildGoldenFixture(t)
	sock := filepath.Join(root, "tools", "sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("cannot create a unix socket here: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	if _, err := ToolsHash(root); err == nil {
		t.Fatal("expected an error for an irregular node, got nil")
	} else if !strings.Contains(err.Error(), "tools/sock") {
		t.Errorf("error does not name the offending path: %v", err)
	}
}

func TestMissingToolsDirectoryIsAnError(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ToolsHash(root); err == nil {
		t.Fatal("expected an error when tools/ is absent, got nil")
	}
}

// TestEmptyToolsDirectoryIsAnError pins [R8]. The digest of an empty stream is
// a valid-looking hex string, and publishing it would reject every user's fork.
func TestEmptyToolsDirectoryIsAnError(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := ToolsHash(root)
	if err == nil {
		t.Fatalf("expected an error for an empty tools/, got digest %s", got)
	}
	// sha256 of the empty input, i.e. what a lenient implementation returns.
	const emptyStream = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if got == emptyStream {
		t.Error("returned the digest of an empty stream")
	}
}

// TestToolsAsASymlinkIsAnError: os.Stat would follow it and report a directory,
// after which the walk hashes nothing at all.
func TestToolsAsASymlinkIsAnError(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "real", "preproc.c"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real", filepath.Join(root, "tools")); err != nil {
		t.Fatal(err)
	}
	if got, err := ToolsHash(root); err == nil {
		t.Fatalf("expected an error when tools/ is a symlink, got digest %s", got)
	}
}

// TestPathsAreRepoRelative pins resolution 1: the hashed path includes the
// leading "tools/" and is not relative to tools/ itself.
func TestPathsAreRepoRelative(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tools", "x.c"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(root, "tools", "x.c"), 0o644); err != nil {
		t.Fatal(err)
	}
	withPrefix := streamDigest([][3]string{{"tools/x.c", "0", "x\n"}})
	withoutPrefix := streamDigest([][3]string{{"x.c", "0", "x\n"}})
	got := mustHash(t, root)
	switch got {
	case withPrefix:
	case withoutPrefix:
		t.Error("paths are relative to tools/, not to the repository root")
	default:
		t.Errorf("unexpected digest %s", got)
	}
}

// TestExecByteIsASCII pins resolution 6: '1' (0x31), not 0x01.
func TestExecByteIsASCII(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(root, "tools", "x.sh")
	if err := os.WriteFile(p, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, 0o755); err != nil {
		t.Fatal(err)
	}
	ascii := streamDigest([][3]string{{"tools/x.sh", "1", "x\n"}})
	raw := streamDigest([][3]string{{"tools/x.sh", "\x01", "x\n"}})
	got := mustHash(t, root)
	switch got {
	case ascii:
	case raw:
		t.Error("exec byte is 0x01; the spec's `0`/`1` are the ASCII characters")
	default:
		t.Errorf("unexpected digest %s", got)
	}
}

// TestRelativeRepoRootWorks: the CLI is expected to be given whatever the
// caller has, including "." or a relative path.
func TestRelativeRepoRootWorks(t *testing.T) {
	root := buildGoldenFixture(t)
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })

	if got := mustHash(t, "."); got != goldenDigest {
		t.Errorf("relative root: got %s, want %s", got, goldenDigest)
	}
}
