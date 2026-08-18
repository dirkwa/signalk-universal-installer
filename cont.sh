set -euo pipefail
f() {
    for x in a b; do
        [[ "$x" == "a" ]] && continue
        echo "processed $x"
    done
}
f
echo "AFTER f — reached, exit ok"
