mock_provider "aws" {}

variables {
  name        = "platform-dev"
  environment = "dev"
  vpc_id      = "vpc-0123456789abcdef0"
  subnet_ids  = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]

  allowed_security_group_ids = ["sg-0123456789abcdef0"]
}

run "single_az_private_mysql" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine == "mysql"
    error_message = "the module must create a MySQL instance."
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.micro"
    error_message = "instance_class must default to db.t4g.micro."
  }

  assert {
    condition     = aws_db_instance.this.multi_az == false
    error_message = "the design requires a single-AZ instance."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "the database must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "the master password must be managed by Secrets Manager."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period >= 1
    error_message = "automated backups must be enabled."
  }

  # db.t4g.micro 不支持 Performance Insights，开启会触发
  # InvalidParameterCombination，所以默认必须关闭。
  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == false
    error_message = "Performance Insights must stay off for db.t4g.micro."
  }
}

run "ingress_is_security_group_scoped" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.mysql) == 1
    error_message = "one ingress rule must be created per allowed security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.mysql[0].referenced_security_group_id == "sg-0123456789abcdef0"
    error_message = "ingress must reference the bastion security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.mysql[0].cidr_ipv4 == null
    error_message = "ingress must not be opened to a CIDR range."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.mysql[0].from_port == 3306
    error_message = "MySQL ingress must use port 3306."
  }
}
