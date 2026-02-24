set shell := ["/bin/bash", "-eu", "-o", "pipefail", "-c"]

# Defaults
bench_target := "x86_64-macos"
bench_optimize := "ReleaseFast"
bench_binary := "./zig-out/bin/ghostty-bench"
bench_actions := "codepoint-width grapheme-break screen-clone terminal-parser terminal-stream is-symbol osc-parser"
bench_iterations := "11"
bench_warmup := "2"

# macOS app profiling defaults
macos_profile_seconds := "10"
macos_profile_runs := "3"
macos_profile_warmup := "2"

# Show available recipes
list:
	@just --list

# Build the benchmark binary (optimized, with a dedicated benchmark artifact)
build-bench target='{{bench_target}}' optimize='{{bench_optimize}}':
	zig build -Dtarget={{target}} -Doptimize={{optimize}} -Demit-bench=true

# Run one benchmark once (e.g. `just bench terminal-stream --terminal-rows 24 --terminal-cols 80`)
bench action='terminal-parser' args='' target='{{bench_target}}' optimize='{{bench_optimize}}':
	just build-bench target={{target}} optimize={{optimize}}
	{{bench_binary}} {{action}} {{args}}

# Run all benchmark actions once
bench-all args='' target='{{bench_target}}' optimize='{{bench_optimize}}':
	just build-bench target={{target}} optimize={{optimize}}
	for action in {{bench_actions}}; do
		echo "==> $action"
		{{bench_binary}} "$action" {{args}}
	done

# Build the macOS app bundle (release by default) for runtime profiling.
build-macos-app target='{{bench_target}}' optimize='{{bench_optimize}}':
	zig build -Dtarget={{target}} -Doptimize={{optimize}} -Demit-macos-app

# Capture app-runtime samples with macOS `sample` (CPU sampling + runtime profile).
#
# This uses the app binary directly from the xcode output tree. If your
# optimization changes the configuration, pass `app_config` explicitly
# (examples: ReleaseLocal, Release, Debug).
bench-macos-app app_config='ReleaseLocal' args='' target='{{bench_target}}' optimize='{{bench_optimize}}' runs='{{macos_profile_runs}}' seconds='{{macos_profile_seconds}}' warmup='{{macos_profile_warmup}}':
	just build-macos-app target={{target}} optimize={{optimize}}
	app_path="macos/build/{{app_config}}/Ghostty.app"
	app_bin="${app_path}/Contents/MacOS/ghostty"
	if [ ! -x "$app_bin" ]; then
		echo "Ghostty app binary not found: $app_bin"
		echo "Run with a matching optimize/config combination for your local Xcode scheme:"
		echo "  just build-macos-app target={{target}} optimize={{optimize}}"
		exit 1
	fi

	mkdir -p .bench
	for run in $(seq 1 {{runs}}); do
		trace=".bench/macos-profile-${run}.sample"
		rm -f "$trace"

		# Ensure app starts once before sampling.
		"${app_bin}" {{args}} >/tmp/ghostty-macos-bench-${run}.log 2>&1 &
		pid=$!
		sleep {{warmup}}

		if ! command -v sample >/dev/null 2>&1; then
			echo "sample(1) not available on this macOS image"
			kill "$pid" >/dev/null 2>&1 || true
			wait "$pid" || true
			exit 1
		fi

		echo "run $run: sampling PID $pid for {{seconds}} seconds -> $trace"
		sample "$pid" {{seconds}} -file "$trace"
		kill -INT "$pid" >/dev/null 2>&1 || true
		wait "$pid" || true
	done

# Run a benchmark many times and summarize wall-clock time.
# Produces:
#   .bench/<action>.raw-time.txt (all raw real times)
#   .bench/<action>.sorted-time.txt (sorted raw times)
# Outputs median, mean, p10, and p90 for simple comparison.
bench-repeat action='terminal-parser' args='' iterations='{{bench_iterations}}' target='{{bench_target}}' optimize='{{bench_optimize}}':
	just build-bench target={{target}} optimize={{optimize}}
	mkdir -p .bench
	raw=".bench/{{action}}.raw-time.txt"
	sorted=".bench/{{action}}.sorted-time.txt"
	rm -f "$raw" "$sorted"

	# Warmup (cache/JIT/runtime warmup)
	for _ in $(seq 1 {{bench_warmup}}); do
		{{bench_binary}} {{action}} {{args}} >/dev/null
	done

	for _ in $(seq 1 {{iterations}}); do
		/usr/bin/time -p {{bench_binary}} {{action}} {{args}} >/dev/null 2>> "$raw"
	done

	awk '/^real / { print $2 }' "$raw" | sort -n > "$sorted"

	count=$(wc -l < "$sorted")
	if [ "$count" -eq 0 ]; then
		echo "no timing samples collected"
		exit 1
	fi

	mid=$(( (count + 1) / 2 ))
	p10=$(( (count * 10 + 50) / 100 ))
	p90=$(( (count * 90 + 50) / 100 ))

	median=$(awk -v m="$mid" 'NR==m {print $1}' "$sorted")
	p10v=$(awk -v m="$p10" 'NR==m {print $1}' "$sorted")
	p90v=$(awk -v m="$p90" 'NR==m {print $1}' "$sorted")
	mean=$(awk '{ sum += $1 } END { if (NR > 0) printf "%.6f", sum / NR }' "$sorted")

	echo "action: {{action}}"
	echo "runs: $count"
	echo "median: ${median}s"
	echo "p10: ${p10v}s"
	echo "p90: ${p90v}s"
	echo "mean: ${mean}s"

# Build production-style macOS artifacts and copy the app bundle to Applications.
#
# Defaults mirror your command:
#   -Dtarget=x86_64-macos -Dcpu=baseline -Doptimize=ReleaseFast -Dstrip=true
#   -Demit-macos-app=true -Demit-xcframework=true
build-macos-release-install \
	install_dir='/Applications' \
	sudo='' \
	target='x86_64-macos' \
	cpu='baseline' \
	optimize='ReleaseFast' \
	strip='true' \
	app_config='ReleaseLocal':
	zig build install \
		-Dtarget={{target}} \
		-Dcpu={{cpu}} \
		-Doptimize={{optimize}} \
		-Dstrip={{strip}} \
		-Demit-macos-app=true \
		-Demit-xcframework=true

	src_app_zig="zig-out/Ghostty.app"
	src_app_xcode="macos/build/{{app_config}}/Ghostty.app"
	if [ -d "$src_app_zig" ]; then
		src="$src_app_zig"
	elif [ -d "$src_app_xcode" ]; then
		src="$src_app_xcode"
	else
		echo "Ghostty.app not found in zig-out or macos/build/{{app_config}}"
		exit 1
	fi

	{{sudo}} rm -rf "{{install_dir}}/Ghostty.app"
	{{sudo}} cp -R "$src" "{{install_dir}}/Ghostty.app"
