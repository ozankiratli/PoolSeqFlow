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

# The value of a parameter in the migrated config. Takes the FIRST match, so it is only safe
# for a key that appears once - `maxDepth` is in both capBAM and variantCall.
migrated_value() {
    sed -n "s|^ *$1 *= *||p" "$MIGRATE_CONFIG" | head -1 | tr -d "\"'" | sed 's/ *\/\/.*//'
}

# The same, within one scope, for a key that more than one scope defines.
migrated_value_in() {
    awk -v scope="$1" -v key="$2" '
        $0 ~ "^[ \t]*" scope "[ \t]*\\{"   { inscope = 1; next }
        inscope && $0 ~ /^[ \t]*\}/        { inscope = 0 }
        inscope && $0 ~ "^[ \t]*" key "[ \t]*=" {
            sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]*\/\/.*$/, "")
            gsub(/["\x27]/, ""); sub(/[ \t]+$/, "")
            print; exit
        }' "$MIGRATE_CONFIG"
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
    # baseQualMin rather than maxDepth, which capBAM defines too and this same sed would set
    # in both scopes, so the assertion could pass on the wrong one.
    migrate_config_with -e 's|^    cleanBAM {|    samtools {|' \
                        -e 's|^    variantCall {|    bcftools {|' \
                        -e 's|^        mapq .*|        mapq            = 44|' \
                        -e 's|^        baseQualMin .*|        baseQualMin     = 41|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "44" "$(migrated_value_in cleanBAM mapq)" "samtools.mapq should land in cleanBAM.mapq"
    assert_eq "41" "$(migrated_value_in variantCall baseQualMin)" \
        "bcftools.baseQualMin should land in variantCall.baseQualMin"
    assert_contains "$MIGRATE_OUTPUT" "cleanBAM.mapq" "the report should name the new key"
    assert_contains "$MIGRATE_OUTPUT" "variantCall.baseQualMin" "the report should name the new key"
}

# THE DEPTH CEILING IS RESET, NOT CARRIED.
#
# 2.2.0's bcftools.maxDepth = 2000 was the only depth ceiling in the pipeline. From 3.0 step 5
# measures a cap per sample and step 6 applies it to the BAM before calling, so this knob is a
# second ceiling over that one and ships as 0 - which mpileup reads as no limit. Carrying 2000
# across would leave a project quietly capped at a depth the release never chose, on top of a
# cap capBAM cannot see. The prefix rename would do exactly that without reformatted().
test_the_depth_ceiling_is_reset_rather_than_carried() {
    migrate_config_with -e 's|^    variantCall {|    bcftools {|' \
                        -e 's|^        maxDepth        = 0|        maxDepth        = 2000|'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_eq "0" "$(migrated_value_in variantCall maxDepth)" \
        "the template's 0 should win over the old 2000"
    assert_contains "$MIGRATE_OUTPUT" "2000" "the report should say what the old value was"
    assert_contains "$MIGRATE_OUTPUT" "variantCall.maxDepth" "and name the parameter"
    # The automatic per-sample cap arrives untouched alongside it.
    assert_eq "-1" "$(migrated_value_in capBAM maxDepth)" \
        "capBAM.maxDepth should still be the measure-it-yourself default"
}

# Every other renamed bcftools setting still carries, so the reformat is one parameter and
# not the whole scope losing its values.
test_the_depth_reset_does_not_disturb_the_rest_of_the_scope() {
    migrate_config_with -e 's|^    variantCall {|    bcftools {|' \
                        -e 's|^        maxDepth        = 0|        maxDepth        = 2000|' \
                        -e 's|^        scaleMapQ .*|        scaleMapQ       = 60|' \
                        -e 's|^        baseQualMin .*|        baseQualMin     = 25|'
    assert_eq "60" "$(migrated_value_in variantCall scaleMapQ)" "scaleMapQ should carry"
    assert_eq "25" "$(migrated_value_in variantCall baseQualMin)" "baseQualMin should carry"
    assert_eq "0" "$(migrated_value_in variantCall maxDepth)" "only maxDepth should be reset"
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

# A PARAMETER THAT BECAME A COMMENTED-OUT KNOB IS NOT A LOSS.
#
# The option strings and the whole cores block are computed now and ship commented out, so the
# user can still take them back. Reported as DROPPED they read as gone for good, and the one
# thing the report should never do is send someone looking for a setting that is right there.
test_a_parameter_that_became_a_knob_is_not_reported_as_dropped() {
    # Uncommenting in the OLD config is what a pre-3.0 config looked like: these were live.
    migrate_config_with -e 's|^        // options |        options    |' \
                        -e 's|^        // ladder |        ladder     |'
    assert_status 0 "$MIGRATE_STATUS" "migration should succeed"
    assert_contains "$MIGRATE_OUTPUT" "Still yours to set" "there should be a knob section"
    assert_contains "$MIGRATE_OUTPUT" "uncomment" "and it should say how to take one back"
    # The section that means gone for good must not claim them.
    local dropped
    dropped=$(printf '%s\n' "$MIGRATE_OUTPUT" | sed -n '/No longer used/,/^$/p')
    assert_not_contains "$dropped" "bwa.options" "an option string is a knob, not a loss"
    assert_not_contains "$dropped" "cores.ladder" "and so is the thread ladder"
}

# The depth ceiling needs more than a one-line report entry: the value did not move, the
# mechanism did, and a user who wants the old behaviour needs two settings changed.
test_the_depth_ceiling_change_is_explained() {
    migrate_config_with -e 's|^    variantCall {|    bcftools {|' \
                        -e 's|^        maxDepth        = 0|        maxDepth        = 2000|'
    assert_contains "$MIGRATE_OUTPUT" "DEPTH CEILING MOVED" "the change should be called out"
    assert_contains "$MIGRATE_OUTPUT" "2000" "naming the value that was not carried"
    assert_contains "$MIGRATE_OUTPUT" "capBAM.maxDepth" "and the knob that replaced it"
    # The escape hatch matters most: someone reproducing old results has to get back exactly.
    assert_contains "$MIGRATE_OUTPUT" "capBAM.maxDepth = 0" \
        "and how to restore the old behaviour exactly"
}

# A config with no ceiling set has nothing to explain, so the note must stay away.
test_the_depth_note_is_absent_when_nothing_changed() {
    migrate_config_with -e 's|^    variantCall {|    bcftools {|'
    assert_not_contains "$MIGRATE_OUTPUT" "DEPTH CEILING MOVED" \
        "a config already at 0 should not be lectured about it"
}

# RGTags.csv -> metadata.csv is the biggest thing a 2.x user has to do by hand, and no report
# line can say it: the parameter is dropped, the file is not, and the format is different.
test_the_sample_table_change_is_explained() {
    migrate_config_with -e "s|^    metadataFile .*|    rgTagsFile      = 'RGTags.csv'|"
    assert_contains "$MIGRATE_OUTPUT" "RGTags.csv IS REPLACED BY metadata.csv" \
        "the replacement should be stated plainly"
    assert_contains "$MIGRATE_OUTPUT" "not the same file renamed" \
        "and that it is not a rename"
    assert_contains "$MIGRATE_OUTPUT" "metadata.csv.template" "with somewhere to start from"
    assert_contains "$MIGRATE_OUTPUT" "refuses at step 0" "and what happens if they skip it"
}

# A project already on metadata.csv must not be told about a file it never had.
test_the_sample_table_note_is_absent_for_a_current_config() {
    migrate_config_with -e 's|^    poolSize .*|    poolSize        = 250|'
    assert_not_contains "$MIGRATE_OUTPUT" "IS REPLACED BY metadata.csv" \
        "a config already using metadata.csv should not see the note"
}
