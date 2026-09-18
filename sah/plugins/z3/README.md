# z3

This preinstalled plugin package makes the chez-z3 bindings available inside
every session-local `eval` environment. The Scheme binding is portable; the Z3
runtime may come from the operating system or from an optional packaged native
artifact.

Runtime resolution is automatic, in this order:

- an explicit `Z3_LIBRARY`;
- a matching optional `native/<chez-machine-type>/` artifact;
- `Z3_HOME`;
- the installation prefix of a `z3` executable found on `PATH`;
- normal dynamic-loader names: `libz3.so`, `libz3.dylib`, `libz3.dll`, or
  `z3.dll`.

An operating-system Z3 package therefore needs no sah configuration when it
exposes the `z3` executable or shared library normally. `Z3_LIBRARY` remains an
escape hatch for unusual layouts, not a routine installation step.

Package contents:

- `plugin.ss` adds the package libraries to the session and selects an optional
  matching native artifact when one exists.
- `upstream/` is the `hgzhehe/chez-z3` git submodule and contains `(z3 raw)`,
  `(z3)`, `(z3 sexpr)`, their generator, tests, examples, and version record.
- `native/ta6nt/libz3.dll` is an optional Windows x64 convenience runtime.
- `Z3.LICENSE.txt` is the upstream Z3 license.

Update the binding from the repository root, then restart sah so Chez does not
reuse an R6RS library already imported by the current process:

```text
git pull --recurse-submodules
git submodule update --init --recursive
```

The plugin imports `(z3)` and `(z3 sexpr)`, so eval code can call their
bindings directly:

```scheme
(call-with-z3-context
  (lambda (context)
    (call-with-z3-solver context
      (lambda (solver)
        (let ((x (z3-int-const context 'x)))
          (z3-solver-assert!
           solver
           (z3> x (z3-int context 10)))
          (z3-solver-check solver))))))
```

The loaded runtime must provide the C API used by this binding. An incompatible
or missing runtime fails during plugin mount with the binding's load error.
