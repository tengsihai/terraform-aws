output "asg_name" {
  description = "Name of the bastion Auto Scaling group."
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "ARN of the bastion Auto Scaling group."
  value       = aws_autoscaling_group.this.arn
}

output "security_group_id" {
  description = "Bastion security group ID (no ingress, all egress)."
  value       = aws_security_group.this.id
}

output "launch_template_id" {
  description = "ID of the bastion launch template."
  value       = aws_launch_template.this.id
}

output "instance_role_arn" {
  description = "Instance role ARN. Only AmazonSSMManagedInstanceCore is attached."
  value       = aws_iam_role.this.arn
}

output "bastion_tag_key" {
  description = "Tag key applied to bastion instances (used by the developer IAM policy)."
  value       = var.bastion_tag_key
}

output "bastion_tag_value" {
  description = "Tag value applied to bastion instances (used by the developer IAM policy)."
  value       = local.bastion_tag_value
}

output "developer_policy_json" {
  description = "Least-privilege IAM policy for developers: ssm:StartSession only, restricted to tagged bastion instances and the port-forwarding document, MFA required."
  value       = jsonencode(local.developer_policy)
}

output "scale_up_command" {
  description = "CLI command that starts one bastion instance."
  value       = "aws autoscaling set-desired-capacity --region ${var.aws_region} --auto-scaling-group-name ${aws_autoscaling_group.this.name} --desired-capacity 1"
}

output "scale_down_command" {
  description = "CLI command that terminates the bastion instance and returns to zero cost."
  value       = "aws autoscaling set-desired-capacity --region ${var.aws_region} --auto-scaling-group-name ${aws_autoscaling_group.this.name} --desired-capacity 0"
}

output "instance_id_command" {
  description = "CLI command that prints the running bastion instance ID."
  value       = "aws autoscaling describe-auto-scaling-groups --region ${var.aws_region} --auto-scaling-group-names ${aws_autoscaling_group.this.name} --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text"
}

output "ssm_ready_command" {
  description = "CLI command that checks whether an SSM-managed instance is online."
  value       = "aws ssm describe-instance-information --region ${var.aws_region} --filters Key=PingStatus,Values=Online --query 'InstanceInformationList[].{InstanceId:InstanceId,ComputerName:ComputerName,PingStatus:PingStatus}' --output table"
}
