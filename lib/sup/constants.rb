module ::Redwood
  BASE_DIR   = ENV["SUP_BASE"] || File.join(ENV["HOME"], ".sup")
  CONFIG_FN  = File.join(BASE_DIR, "config.yaml")
  COLOR_FN   = File.join(BASE_DIR, "colors.yaml")
  SOURCE_FN  = File.join(BASE_DIR, "sources.yaml")
  LABEL_FN   = File.join(BASE_DIR, "labels.txt")
  CONTACT_FN = File.join(BASE_DIR, "contacts.txt")
  DRAFT_DIR  = File.join(BASE_DIR, "drafts")
  SENT_FN    = File.join(BASE_DIR, "sent.mbox")
  LOCK_FN    = File.join(BASE_DIR, "lock")
  SUICIDE_FN = File.join(BASE_DIR, "please-kill-yourself")
  HOOK_DIR   = File.join(BASE_DIR, "hooks")
  SEARCH_FN  = File.join(BASE_DIR, "searches.txt")
  LOG_FN     = File.join(BASE_DIR, "log")
  SYNC_OK_FN = File.join(BASE_DIR, "sync-back-ok")

  YAML_DOMAIN = "supmua.org"
  LEGACY_YAML_DOMAIN = "masanjin.net"
  YAML_DATE = "2006-10-01"
  MAILDIR_SYNC_CHECK_SKIPPED = 'SKIPPED'
  URI_ENCODE_CHARS = "!*'();:@&=+$,?#[] " # see https://en.wikipedia.org/wiki/Percent-encoding
end
