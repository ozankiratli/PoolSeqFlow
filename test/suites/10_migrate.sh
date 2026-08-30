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

# The 3.0 scope renames: samtools -> cleanBAM, bcftools -> variantCall. Whole scopes moved, so
# the rename table matches on the PREFIX rather than listing every field; a 2.x config names
# eight of them. Without this the user's calling and cleaning settings all read as DROPPED and
# they silently get the template defaults back.
test_the_option_scopes_carry_over_from_their_tool_names() {
    migrate_config_with -e 's|^    cleanBAM {|    samtools {|' \
                        -e 's|^    variantCall {|    bcftools {|' \
                        -e 's|^        mapq .*|        mapq            = 44|' \
                        -e 's|^        maxDepth .*|        maxDepth        = 7777|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "44" "$(migrated_value mapq)" "samtools.mapq should land in cleanBAM.mapq"
    assert_eq "7777" "$(migrated_value maxDepth)" \
        "bcftools.maxDepth should land in variantCall.maxDepth"
    assert_contains "$MIGRATE_OUTPUT" "cleanBAM.mapq" "the report should name the new key"
    assert_contains "$MIGRATE_OUTPUT" "variantCall.maxDepth" "the report should name the new key"
}

# The `software` block names the TOOLS and was deliberately left alone by the same rename. A
# prefix rule that reached `software.samtools` would repoint a user's binary at a scope that
# does not exist, and nothing downstream would say so.
test_the_scope_rename_leaves_the_software_block_alone() {
    migrate_config_with -e 's|^    cleanBAM {|    samtools {|' \
                        -e 's|^    variantCall {|    bcftools {|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "samtools" "$(migrated_value samtools)" "software.samtools must stay the tool name"
    assert_eq "bcftools" "$(migrated_value bcftools)" "software.bcftools must stay the tool name"
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

# The cases above use the script's defaults, which resolve all three files in the current
# directory. That is no longer how the wrapper calls it: the template ships with the
# installation while the config belongs to the project, so ./PoolSeqFlow migrate_config now
# passes the template by absolute path. The backup must still land beside the user's config
# rather than next to the template.
test_the_template_may_live_outside_the_project() {
    local sb out status value
    sb=$(guard_path "$TEST_TMPDIR/migrate-split")
    rm -rf "$sb"
    mkdir -p "$sb/install/bin" "$sb/project"
    cp "$REPO_ROOT/bin/config_migrate.sh" "$sb/install/bin/"
    cp "$REPO_ROOT/parameters.config.template" "$sb/install/"
    sed -e 's|^    storageDir .*|    projectDir      = "/data/my_experiment"|' \
        "$REPO_ROOT/parameters.config.template" > "$sb/project/parameters.config"

    out=$(cd "$sb/project" && bash "$sb/install/bin/config_migrate.sh" \
              parameters.config "$sb/install/parameters.config.template" parameters.config 2>&1)
    status=$?
    assert_status 0 "$status" "migration should succeed with the template in another directory"

    value=$(sed -n 's|^ *storageDir *= *||p' "$sb/project/parameters.config" \
            | head -1 | tr -d "\"'" | sed 's/ *\/\/.*//')
    assert_eq "/data/my_experiment" "$value" "the value should still carry across the rename"
    assert_contains "$out" "storageDir" "the report should still name the parameter"
    assert_file "$sb/project/parameters.config.bak" "the backup belongs beside the user's config"
}
