require 'json'
require 'aws-sdk-securityhub'

class ComplianceReport
  def initialize(aws_account_id, report, node)
    @aws_account_id = aws_account_id
    @report = report
    @node = node
    @shclient = Aws::SecurityHub::Client.new
  end

  def report
    @report
  end

  def node
    @node
  end

  def aws_account_id
    @aws_account_id
  end

  def node_name
    report['node_name']
  end

  def node_id
    report['node_id']
  end

  def report_timestamp
    Time.at(report['end_time']['seconds']).iso8601.to_s
  end

  def chef_server
    report['chef_server']
  end

  def chef_org
    report['chef_organization']
  end

  def report_id
    report['id']
  end

  def automate_server
    node['automate_fqdn']
  end

  def process_report
    puts "Report for node #{node_name} from #{chef_server}/#{chef_org} reported via #{automate_server}"
    report['profiles'].each do |profile|
      process_profile(profile)
    end
  end

  def process_profile(profile)
    puts "Processing profile #{profile['name']}"
    findings = []

    profile['controls'].each do |control|

      # An array of findings to be sent to AWS Security Hub
      control_failed=false
      control['results'].each do |result|
        if result['status'] == "failed"
          control_failed = true
        end
      end unless control['results'].nil?

      if control_failed  
        finding = {
          schema_version: "2018-10-08",
          id: "#{profile['name']} #{control['id']}",
          product_arn: "arn:aws:securityhub:#{ENV['AWS_REGION']}:#{aws_account_id}:product/#{aws_account_id}/default",
          generator_id: "Inspec #{profile['name']}",
          aws_account_id: "#{aws_account_id}",
          types: ["Other"],
          last_observed_at: report_timestamp,
          created_at: report_timestamp,
          updated_at: report_timestamp,
          severity: {
            label: "HIGH", # accepts INFORMATIONAL, LOW, MEDIUM, HIGH, CRITICAL
          },
          title: "#{profile['name']} - #{control['id']}",
          description: "#{profile['name']} - #{control['id']}",
          resources: [
            type: "Other",
            id: "#{chef_server}/#{chef_org}/#{node_name}",
            partition: "aws",
            region: ENV['AWS_REGION'],
          ],
          workflow: {
            status: "NEW"
          }
        }
        findings << finding
      end
    end unless profile['controls'].nil?
    if findings.length > 0
      puts "Sending #{findings.length} results"
      puts @shclient.batch_import_findings(findings: findings)
    end
  end
end

#################################################################################
# This is the Lambda entry point that receives messages from A2 Data Tap
#################################################################################
def lambda_handler(event:, context:)
  puts "Message packet arrived from #{event['requestContext']['identity']['sourceIp']}"
  body = event['body']
  aws_account_id = event['requestContext']['accountId']
  # The body may contain more than one report delimited by line breaks
  puts "Packet contains #{body.lines.length} messages"
  body.lines.each do |json_message|
    message = JSON.parse(json_message)
    if message['report']
      ComplianceReport.new(aws_account_id, message['report'], message['node']).process_report
    else
      puts "Skipping message as it is not a compliance report"
    end
    { statusCode: 200, body: JSON.generate(result:'Success') }
  end
end