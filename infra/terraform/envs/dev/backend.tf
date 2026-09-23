# Bucket and prefix are supplied by `-backend-config` at init, from the
# Makefile's PROJECT and ENV.
#
# They used to be literals here, which made the state bucket the one value
# that lived in two files — and pointing an apply at a different project
# meant editing a committed file and remembering to change it back. Now
# `make up ENV=dev PROJECT=other-project` is the whole difference.
terraform {
  backend "gcs" {}
}
