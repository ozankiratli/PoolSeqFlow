<!-- The standing tail of every GitHub release body: what does not change from release to
     release. The part that DOES change is this version's CHANGELOG.md section, which
     dev/scripts/changelog-section.sh extracts and release.yml puts above this.

     @VERSION@ and @NAME@ are substituted by release.yml. It lives in a file rather than inside
     the workflow because it is markdown full of backticks and fenced blocks, which a YAML block
     scalar and a shell heredoc each mangle in their own way.
-->

## Download and install

```bash
curl -LO https://github.com/ozankiratli/PoolSeqFlow/releases/download/v@VERSION@/@NAME@.tar.gz
tar -xzf @NAME@.tar.gz
cd @NAME@

cp parameters.config.template parameters.config
./PoolSeqFlow install
```

Then edit `parameters.config` and `metadata.csv` for your data and run
`./PoolSeqFlow run`.

Verify the download with `sha256sum -c SHA256SUMS`.

`PoolSeqFlow.tar.gz` is the same archive under a stable name, for
scripted installs:
`https://github.com/ozankiratli/PoolSeqFlow/releases/latest/download/PoolSeqFlow.tar.gz`

**Upgrading an existing project?** Your `parameters.config` is not
touched by a new version and can be missing parameters this release
expects. Run `./PoolSeqFlow migrate_config` and read what it reports —
see [Upgrading](https://ozankiratli.github.io/PoolSeqFlow/getting-started/upgrading/).

Full documentation: <https://ozankiratli.github.io/PoolSeqFlow/>
The full changelog, including every commit, is in `CHANGELOG.md` in the download and in the repository.
