# tf-kinesis-redshift-etl
Example project for ingesting data from Kinesis and making them available on Redshift

## Instructions
* create a `secrets.tfvars` file in the `dev` folder with following content and your according IDs and credentials:
```
aws_account_id = ""
rs_master_pwd = ""
```

* open Terminal in `dev` folder and run
```
terraform init
```

* provision the required POC resources with
```
terraform apply -var-file secrets.tfvars
```
