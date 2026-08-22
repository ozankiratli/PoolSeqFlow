#!/bin/bash
# bin/config_migrate.sh, against configs written for earlier releases.
#
# A rename is the case that matters here. Without an entry in the script's rename table it
# is two unrelated events - one DROPPED, one NEW - and the user silently gets the template
# default back in place of the value they set.

# Build a config in the sandbox from the current template, with substitutions applied, and
# migrate it. Results land in MIGRATE_OUTPUT / MIGRATE_STATUS / MIGRATE_CONFIG.
#
# Assigned in the caller's shell rather than echoed: a function called inside a command
# substitution runs in a subshell and its variables never reach the caller.
migrate_config_with() {
    local sb
    sb=$(guard_path "$TEST_TMPDIR/migrate")
    rm -rf "$sb"
    mkdir -p "$sb/bin"
    cp "$REPO_ROOT/bin/config_migrate.sh" "$sb/bin/"
    cp "$REPO_ROOT/parameters.config.template" "$sb/"
    sed "$@" "$REPO_ROOT/parameters.config.template" > "$sb/parameters.config"
    MIGRATE_CONFIG="$sb/parameters.config"
    MIGRATE_OUTPUT=$(cd "$sb" && bash bin/config_migrate.sh 2>&1)
    MIGRATE_STATUS=$?
}

# The value of a parameter in the migrated config.
migrated_value() {
    sed -n "s|^ *$1 *= *||p" "$MIGRATE_CONFIG" | head -1 | tr -d "\"'" | sed 's/ *\/\/.*//'
}

# projectDir -> storageDir. Every path in the config is built from it, so losing the value
# would point a returning user's run at /path/to/permanent/storage.
test_storagedir_carries_over_from_projectdir() {
    migrate_config_with \
        -e 's|^    storageDir .*|    projectDir      = "/data/my_experiment"|' \
        -e 's|^    poolSize .*|    poolSize        = 250|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "/data/my_experiment" "$(migrated_value storageDir)" \
        "the old projectDir value should end up in storageDir"
    assert_not_contains "$(migrated_value storageDir)" "/path/to/" \
        "the template placeholder must not win"
    # An unrelated setting alongside it, to show the rename does not disturb the rest.
    assert_eq "250" "$(migrated_value poolSize)" "other settings should carry across too"
}

# The rename should be reported, not performed silently - a user who reads the report has
# to be able to see where their value went.
test_migration_reports_the_rename() {
    migrate_config_with -e 's|^    storageDir .*|    projectDir      = "/data/my_experiment"|'
    assert_contains "$MIGRATE_OUTPUT" "storageDir" "the report should mention the new name"
}

# A config already using the new name must survive migration unchanged.
test_a_current_config_migrates_to_itself() {
    migrate_config_with -e 's|^    storageDir .*|    storageDir      = "/data/already_new"|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "/data/already_new" "$(migrated_value storageDir)" \
        "an already-current config should keep its value"
}

# The v2.2.0 rename, still covered: vcftools.minDP -> vcffilter.minDP. Regression guard for
# the rename table as a whole, not just the entry added most recently.
test_vcffilter_rename_still_carries_over() {
    migrate_config_with -e 's|^        minDP .*|        minDP           = 99|' \
                        -e 's|^    vcffilter {|    vcftools {|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "99" "$(migrated_value minDP)" "the user's minDP should survive the rename"
}

# The brace-with-trailing-comment case: `vcftools {  // comment` once matched neither the
# scope-open rule nor the assignment rule, so the whole block's children were qualified one
# level short and every value in it was dropped.
test_a_commented_block_opening_still_migrates() {
    migrate_config_with -e 's|^        minDP .*|        minDP           = 77|' \
                        -e 's|^    vcffilter {|    vcftools {   // VCF filtering|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "77" "$(migrated_value minDP)" \
        "a value inside a block whose opening brace carries a comment should survive"
}
