mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }
}

variables {
  name        = "platform-dev"
  environment = "dev"
  aws_region  = "ap-northeast-1"
  account_id  = "123456789012"
  vpc_id      = "vpc-0123456789abcdef0"
  subnet_ids  = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
  ami_id      = "ami-0123456789abcdef0"
}

run "asg_starts_at_zero" {
  command = plan

  assert {
    condition     = aws_autoscaling_group.this.min_size == 0
    error_message = "min_size must default to 0 so an idle bastion costs nothing."
  }

  assert {
    condition     = aws_autoscaling_group.this.max_size == 1
    error_message = "max_size must default to 1; the design caps the bastion at a single instance."
  }

  assert {
    condition     = aws_autoscaling_group.this.desired_capacity == 0
    error_message = "desired_capacity must default to 0."
  }
}

run "launch_template_is_private_and_disposable" {
  command = plan

  assert {
    condition     = aws_launch_template.this.instance_type == "t4g.micro"
    error_message = "instance_type must default to t4g.micro."
  }

  assert {
    condition     = aws_launch_template.this.key_name == null
    error_message = "the bastion must not use a key pair."
  }

  assert {
    condition     = aws_launch_template.this.block_device_mappings[0].ebs[0].delete_on_termination == "true"
    error_message = "the root volume must be deleted with the instance."
  }

  assert {
    condition     = aws_launch_template.this.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "the root volume must be encrypted."
  }

  assert {
    condition     = aws_launch_template.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_launch_template.this.network_interfaces[0].associate_public_ip_address == "true"
    error_message = "the bastion needs a public IPv4 to reach the SSM public endpoint through the IGW."
  }
}

run "developer_policy_is_scoped_and_requires_mfa" {
  command = plan

  assert {
    condition     = jsondecode(output.developer_policy_json).Statement[0].Condition.StringEquals["ssm:resourceTag/Bastion"] == "platform-dev-bastion"
    error_message = "the developer policy must restrict StartSession to the bastion tag."
  }

  assert {
    condition     = jsondecode(output.developer_policy_json).Statement[0].Condition.Bool["aws:MultiFactorAuthPresent"] == "true"
    error_message = "the developer policy must require MFA."
  }

  assert {
    condition     = jsondecode(output.developer_policy_json).Statement[1].Resource[0] == "arn:aws:ssm:ap-northeast-1::document/AWS-StartPortForwardingSessionToRemoteHost"
    error_message = "the policy must be restricted to the port-forwarding document."
  }
}
