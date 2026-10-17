# Contributing to AI Cockpit

Thank you. Small things help most.

1. **Translations.** In the app: language menu, *Translate Cockpit…*. Every text is listed with its English; the local model can draft the
   empty ones (you read and correct). Keep every `{placeholder}` exactly as written. Send the finished file through the form on the website.
2. **Bug reports.** Say which system you are on, the version and build shown in the header, what you did, what you expected, what happened.
3. **Code.** The app is PHP and plain JavaScript with no build step; the engine, shell and supervisor are Free Pascal.
   - Before a pull request: `bash tests/<area>_test.sh` for what you touched, and the checks in `Installs/` (`check_translatable.sh`,
     `check_help_topics.sh`, `check_element_ids.sh`, `check_assets.sh`).
   - New interface text goes through `T('key', 'English')` or `data-i18n`; run `php Installs/lang_annotate.php` and `php Installs/lang_extract.php`.
   - Keep the wording plain, and never single out one language, nation or person as a special case.
4. **Licence.** By contributing you agree your contribution is under the same licence as the project (Apache-2.0 with conditions; see `LICENSE.md`).
