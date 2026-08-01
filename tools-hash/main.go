// Command tools-hash computes the `toolsHash` of a Gen 3 decompilation
// checkout: a fingerprint of the repository's tools/ directory.
//
// RotomLab publishes prebuilt host tools alongside a pinned decomp commit, so
// users need no C compiler. When a user points the app at a custom repository —
// a fork — the app hashes that fork's tools/ and compares it against the
// published toolsHash. Equal means the prebuilt binaries were built from these
// exact sources and are safe to use; different means the fork has modified the
// build tools and the project is refused with an explanation, rather than
// failing later as a confusing compiler error.
//
// Two independent implementations have to agree on the value — this one, which
// CI runs when publishing, and the desktop app's. So the algorithm is specified
// rather than left to convention:
//
//	Walk tools/ recursively, excluding tools/agbcc. Sort entries by their
//	repo-relative path using byte-wise ordering. For each file, feed into a
//	SHA-256 stream: the path, a NUL byte, the executable bit as `0` or `1`, a
//	NUL byte, the file contents, and a NUL byte. Symlinks hash their target
//	string rather than being followed. The hex digest is toolsHash.
//	  — docs/superpowers/specs/2026-08-01-toolchain-manager-design.md
//
// tools/agbcc is excluded deliberately: it is a vendored compiler, irrelevant
// to modern builds, and its presence varies between checkouts.
//
// # Resolutions
//
// That prose does not fully determine a digest. Each gap is resolved below,
// marked [Rn] where the code implements it. Anything changed here changes every
// published hash, so the reasoning is recorded rather than left to be
// rediscovered from the bytes.
//
// [R1] "repo-relative path" means relative to the repository root, so
// "tools/preproc/preproc.c" and not "preproc/preproc.c". That is what the words
// say, and the prefix keeps the paths meaningful if the hashed set is ever
// widened beyond tools/. Separators are always "/", so a Windows run of the
// desktop app agrees with a Linux run of CI.
//
// [R2] Directories are not entries. The spec says "for each file", and hashing
// directory entries would make an empty directory significant — but git cannot
// represent an empty directory, so a pristine --depth 1 clone never contains
// one. Hashing them would make a git checkout and a tarball copy of the same
// tree disagree. The accepted consequence is that an empty directory is
// invisible to the digest; it contains no build tool, so nothing is lost.
//
// [R3] A symlink's exec byte is always '0'. A symlink's own mode bits are
// meaningless — 0777 on Linux, copied from the target on some systems, and not
// preserved by every archiver. Feeding them in would make the digest depend on
// the host rather than on the repository.
//
// [R4] Irregular entries — sockets, fifos, devices — are an error naming the
// path, not a silent skip. This hash exists to detect modification; a variant
// that quietly ignores entry kinds it does not understand is one that can be
// made to ignore things. A decomp tools/ never legitimately contains one, so an
// error here costs nothing and a silent skip would hide a real anomaly.
//
// [R5] The exclusion covers tools/agbcc itself and its entire subtree, matched
// as an exact repo-relative path. tools/agbcc-notes.md and tools/x/agbcc are
// ordinary content: a prefix or substring match would silently drop files the
// published binaries were actually built from.
//
// [R6] The exec byte is the ASCII character '0' (0x30) or '1' (0x31). The spec
// writes them in backticks as `0` and `1`, which reads as characters, and it is
// the choice that survives being eyeballed in a hexdump.
//
// [R7] (not asked, but load-bearing) "the executable bit" is any of the three
// execute bits: mode&0o111 != 0. Git records only the owner bit, and a checkout
// under a restrictive umask yields 0700 rather than 0755 — still owner-exec, so
// the two readings agree on every tree git can produce. Any-bit is chosen
// because it matches what "is this executable" means to a shell.
//
// [R8] (also not asked) A tools/ that is absent, is not a directory, or holds
// no files at all is an error rather than the digest of an empty stream. That
// digest is a perfectly ordinary-looking hex string, and CI publishing it —
// after a clone that half-failed, or a hash taken from the wrong directory —
// would reject every user's custom source forever, silently, and surface only
// much later as universal rejection with no obvious cause.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// toolsDir is the only directory hashed, and agbccPath the only exclusion, both
// as repo-relative slash paths.
const (
	toolsDir  = "tools"
	agbccPath = "tools/agbcc"
)

// entry is one hashable node: a regular file or a symlink.
type entry struct {
	// path is repo-relative with "/" separators [R1].
	path string
	// abs is the on-disk path used to read the payload.
	abs string
	// symlink selects the payload: the link target string, or file contents.
	symlink bool
	// exec is the executable bit [R7]; always false for symlinks [R3].
	exec bool
}

// ToolsHash returns the hex SHA-256 digest fingerprinting repoRoot's tools/
// directory, per the algorithm documented at the top of this file.
func ToolsHash(repoRoot string) (string, error) {
	entries, err := collect(repoRoot)
	if err != nil {
		return "", err
	}

	// Sort by the full repo-relative path, byte-wise. Go's string comparison is
	// byte-wise, so this is the required ordering with no collation involved.
	//
	// This global sort is not the same as the walk's own order, and the
	// difference is not cosmetic. filepath.WalkDir visits lexically *within
	// each directory*, so given tools/a.c and tools/a/nested.c it descends into
	// tools/a/ first ("a" < "a.c") and emits tools/a/nested.c before
	// tools/a.c. Byte-wise ordering of the full paths puts tools/a.c first,
	// because '.' (0x2E) sorts before '/' (0x2F). Two implementations that
	// disagree here produce different digests only for repositories that
	// happen to contain such a pair — which is exactly the kind of divergence
	// that surfaces in production rather than in testing.
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].path < entries[j].path
	})

	h := sha256.New()
	for _, e := range entries {
		if err := writeEntry(h, e); err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// collect walks repoRoot/tools and returns every hashable entry, unsorted.
func collect(repoRoot string) ([]entry, error) {
	root := filepath.Join(repoRoot, toolsDir)
	// Lstat, not Stat: if tools/ is itself a symlink, filepath.WalkDir would
	// hand the walk function a symlink entry for the root and descend into
	// nothing, yielding the digest of an empty stream. [R8] says say so instead.
	info, err := os.Lstat(root)
	if err != nil {
		// A missing tools/ is not an empty tools/. Returning the digest of
		// nothing would let a wrong repoRoot — or a clone that failed halfway —
		// produce a confident, meaningless hash. [R8]
		return nil, fmt.Errorf("tools-hash: %s: %w", root, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("tools-hash: %s is not a directory (mode %s)", root, info.Mode().Type())
	}

	var entries []entry
	err = filepath.WalkDir(root, func(abs string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		rel, err := repoRelative(repoRoot, abs)
		if err != nil {
			return err
		}
		if rel == toolsDir {
			return nil // the tools/ directory itself
		}

		// [R5] tools/agbcc and everything beneath it. Returning SkipDir here
		// prunes the subtree; the exact-path comparison keeps tools/agbcc-notes
		// and tools/x/agbcc in.
		if rel == agbccPath {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		typ := d.Type()
		switch {
		case typ&fs.ModeSymlink != 0:
			// [R3] Checked before IsDir, and WalkDir does not follow symlinks,
			// so a symlink to a directory is an entry rather than a subtree.
			entries = append(entries, entry{path: rel, abs: abs, symlink: true})
			return nil
		case d.IsDir():
			return nil // [R2] traversed, not hashed
		case typ.IsRegular():
			fi, err := d.Info()
			if err != nil {
				return err
			}
			entries = append(entries, entry{
				path: rel,
				abs:  abs,
				exec: fi.Mode().Perm()&0o111 != 0, // [R7]
			})
			return nil
		default:
			// [R4] socket, fifo, device, or anything else unexpected.
			return fmt.Errorf("tools-hash: %s: unsupported entry type %s", rel, typ)
		}
	})
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		// [R8] No pristine decomp has an empty tools/. If CI ever hashed one —
		// a clone that half-failed, a copy taken from the wrong directory — the
		// digest of nothing is a perfectly valid-looking hex string, and
		// publishing it would reject every user's fork forever, silently and
		// long after the fact.
		return nil, fmt.Errorf("tools-hash: %s contains no files", root)
	}
	return entries, nil
}

// repoRelative converts an absolute-or-relative on-disk path into the
// repo-relative slash path that goes into the stream [R1].
func repoRelative(repoRoot, abs string) (string, error) {
	rel, err := filepath.Rel(repoRoot, abs)
	if err != nil {
		return "", fmt.Errorf("tools-hash: %s: %w", abs, err)
	}
	rel = filepath.ToSlash(rel)
	if rel == ".." || strings.HasPrefix(rel, "../") {
		// Cannot happen for a walk rooted inside repoRoot, but a path that
		// escaped the repository must never be hashed under a relative name.
		return "", fmt.Errorf("tools-hash: %s lies outside %s", abs, repoRoot)
	}
	return rel, nil
}

// writeEntry appends one entry to the digest stream:
//
//	path NUL exec NUL payload NUL
//
// where exec is '0' or '1' [R6] and payload is the link target string for a
// symlink, or the file's contents otherwise.
func writeEntry(h io.Writer, e entry) error {
	execByte := byte('0')
	if e.exec {
		execByte = '1'
	}
	if _, err := io.WriteString(h, e.path); err != nil {
		return err
	}
	if _, err := h.Write([]byte{0, execByte, 0}); err != nil {
		return err
	}

	if e.symlink {
		target, err := os.Readlink(e.abs)
		if err != nil {
			return fmt.Errorf("tools-hash: %s: %w", e.path, err)
		}
		// The target is hashed exactly as recorded — not cleaned, not resolved.
		// Cleaning would let "./x" and "x" collide, and resolving would defeat
		// the point of not following it.
		if _, err := io.WriteString(h, filepath.ToSlash(target)); err != nil {
			return err
		}
	} else {
		f, err := os.Open(e.abs)
		if err != nil {
			return fmt.Errorf("tools-hash: %s: %w", e.path, err)
		}
		// Streamed rather than read whole: tools/ can contain multi-megabyte
		// binaries when the caller hashes a tree that has already been built.
		_, copyErr := io.Copy(h, f)
		closeErr := f.Close()
		if copyErr != nil {
			return fmt.Errorf("tools-hash: %s: %w", e.path, copyErr)
		}
		if closeErr != nil {
			return fmt.Errorf("tools-hash: %s: %w", e.path, closeErr)
		}
	}

	_, err := h.Write([]byte{0})
	return err
}

func main() {
	if len(os.Args) != 2 || os.Args[1] == "-h" || os.Args[1] == "--help" {
		fmt.Fprintf(os.Stderr, "usage: %s <repo-root>\n\n", filepath.Base(os.Args[0]))
		fmt.Fprint(os.Stderr, "Prints the toolsHash of <repo-root>/tools as a hex SHA-256 digest.\n")
		os.Exit(2)
	}

	digest, err := ToolsHash(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		if errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintln(os.Stderr, "hint: <repo-root> is the decomp checkout, the directory containing tools/")
		}
		os.Exit(1)
	}
	fmt.Println(digest)
}
