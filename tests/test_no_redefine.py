"""No script defines the same top-level CONSTANT or function twice: python3 tests/test_no_redefine.py
(halcyon-ai.py once had two `RULES` tables; the second silently replaced the first and `>do` crashed on import order.)"""
import ast, glob, os, sys

here = os.path.dirname(os.path.abspath(__file__))
files = sorted(glob.glob(os.path.join(here, "..", "scripts", "*.py")) + glob.glob(os.path.join(here, "..", "quickshell", "island", "scripts", "*.py")))
bad = 0
for path in files:
    try:
        tree = ast.parse(open(path, encoding="utf-8").read(), path)
    except SyntaxError as e:
        print(f"FAIL {os.path.relpath(path, here)}: {e}")
        bad += 1
        continue
    seen = {}
    for node in tree.body:                    # only the module level: a name set again inside if / try is a deliberate fallback
        names = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names = [node.name]
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names = [t.id for t in targets if isinstance(t, ast.Name) and t.id.isupper() and len(t.id) > 1]
        for n in names:
            if n in seen:
                print(f"FAIL {os.path.relpath(path, os.path.join(here, '..'))}: {n} defined on line {seen[n]} and again on line {node.lineno}")
                bad += 1
            else:
                seen[n] = node.lineno
print(f"{len(files)} scripts checked" if not bad else f"{bad} redefinition(s)")
sys.exit(1 if bad else 0)
