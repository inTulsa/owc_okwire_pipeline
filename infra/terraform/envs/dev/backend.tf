# State bucket is created out of band during bootstrap — Terraform cannot
# create the bucket that holds its own state. See docs/03-gcp-setup.md.
terraform {
  backend "gcs" {
    bucket = "gcs-owc-dpar-td-tfstate-1"
    prefix = "env/dev"
  }
}
