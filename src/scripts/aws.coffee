# Description:
#   Queries for the status of AWS services
#
# Dependencies:
#   "aws2js": "0.6.12"
#   "underscore": "1.3.3"
#   "moment": "1.6.2"
#
# Configuration:
#   HUBOT_AWS_ACCESS_KEY_ID
#   HUBOT_AWS_SECRET_ACCESS_KEY
#   HUBOT_AWS_SQS_REGIONS
#   HUBOT_AWS_EC2_REGIONS
#
# Commands:
#   hubot sqs status - Returns the status of SQS queues
#   hubot ec2 status - Returns the status of EC2 instances
#
# Notes:
#   It's highly recommended to use a read-only IAM account for this purpose
#   https://console.aws.amazon.com/iam/home?
#   SQS - requires ListQueues, GetQueueAttributes and ReceiveMessage
#   EC2 - requires EC2:Describe*, elasticloadbalancing:Describe*, cloudwatch:ListMetrics, 
#   cloudwatch:GetMetricStatistics, cloudwatch:Describe*, autoscaling:Describe*
#
# Author:
#   Ethan J. Brown

key = process.env.HUBOT_AWS_ACCESS_KEY_ID
secret = process.env.HUBOT_AWS_SECRET_ACCESS_KEY

_ = require 'underscore'
moment = require 'moment'
aws = require 'aws2js'
sqs = aws
  .load('sqs', key, secret)
  .setApiVersion('2011-10-01')
ec2 = aws
  .load('ec2', key, secret)
  .setApiVersion('2012-05-01')


# Node types: MASTER, CORE, TASK
getRegionEMRClusters = (region, msg) ->
    ec2.setRegion(region).request 'DescribeInstances', (error, reservations) ->
        if error?
            msg.send "Failed to describe instances for region #{region} - error #{error}"
            return
        ec2.setRegion(region).request 'DescribeInstanceStatus', (error, allStatuses) ->
            statuses = if error? then [] else allStatuses.instanceStatusSet.item
            instances = _.flatten [reservations?.reservationSet?.item ? []]
            instances = _.pluck instances, 'instancesSet'
            instances = _.flatten _.pluck instances, 'item'
            clusters = {}

            for instance in instances
                do (instance) ->
                    status = _.find statuses, (s) ->
                      instance.instanceId == s.instanceId
                    suffix = ''
                    state = instance.instanceState.name
                    excl = String.fromCharCode 0x203C
                    dexcl = excl + excl
                    if instance.tagSet != undefined then tags = _.flatten [instance.tagSet.item] else tags = []
                    cluster_node_type_container = (_.find tags, (t) -> t.key == 'aws:elasticmapreduce:instance-group-role')
                    cluster_flow_name_container = (_.find tags, (t) -> t.key == 'aws:elasticmapreduce:job-flow-id')

                    if ( state == 'pending' or state == 'running' ) and cluster_node_type_container != undefined
                        cluster_id = (_.find tags, (t) -> t.key == 'aws:elasticmapreduce:job-flow-id').value
                        node_type = cluster_node_type_container.value
                        if cluster_id not in clusters then clusters[cluster_id] = {'MASTER': 0, 'CORE': 0, 'TASK': 0, 'UNKNWN': 0}
                        if clusters[cluster_id][node_type] != undefined then clusters[cluster_id][node_type] = clusters[cluster_id][node_type] + 1 else clusters[cluster_id]['UNKNWN'] = clusters[cluster_id]['UNKNWN'] + 1
                        if node_type == 'MASTER'
                            master_tags = [] 
                            for tagPair in tags
                                do (tagPair) ->
                                    master_tags.push [tagPair.key, tagPair.value] if tagPair.key.indexOf('aws') != 0
                            clusters[cluster_id]['state'] = state
                            clusters[cluster_id]['tags'] = master_tags
                            switch state
                                when 'pending' then prefix = String.fromCharCode 0x25B2
                                when 'running' then prefix = String.fromCharCode 0x25BA
                                when 'shutting-down' then prefix = String.fromCharCode 0x25BC
                                when 'terminated' then prefix = String.fromCharCode 0x25AA
                                when 'stopping' then prefix = String.fromCharCode 0x25A1
                                when 'stopped' then prefix = String.fromCharCode 0x25A0
                                else prefix = dexcl
                            clusters[cluster_id]['prefix'] = prefix
                          

                            if status?
                                bad = _.filter [status.systemStatus, status.instanceStatus],
                                (s) -> s.status != 'ok'

                                if bad.length > 0
                                    prefix = dexcl
                                    badStrings = _.map bad, (b) ->
                                        b.details.item.name + ' ' + b.details.item.status
                                    concat = (memo, s) -> memo + s
                                    suffix = _.reduce badStrings, concat, ''

                                iEvents = _.flatten [status.eventsSet?.item ? []]
                                if not _.isEmpty iEvents then prefix = dexcl
                                desc = (memo, e) -> "#{memo} #{dexcl}#{e.code} : #{e.description}"
                                suffix += _.reduce iEvents, desc, ''
                            clusters[cluster_id]['suffix'] = suffix 

                            type = instance.instanceType
                            clusters[cluster_id]['type'] = type
                            dnsName = if _.isEmpty instance.dnsName then 'N/A' else instance.dnsName
                            clusters[cluster_id]['dnsName'] = dnsName
                            launchTime = moment(instance.launchTime).format 'ddd, L LT'
                            clusters[cluster_id]['launchTime'] = launchTime
            for key, value of clusters
                status_str = "\nCluster : #{key}\n"
                for tag in value['tags']
                    do (tag) ->
                        status_str += "#{tag[0]}: #{tag[1]}\n"
                status_str += "State: #{value['prefix']} #{value['state']}\nMaster Node Type: #{value['type']}\nMaster External DNS: #{value['dnsName']}\nRegion: #{region}\nLaunch Time: #{value['launchTime']}\nNode Counts:\n\tCORE:   #{value['CORE']}\n\tTASK:   #{value['TASK']}\n\tMASTER: #{value['MASTER']}\n\tUNKNOWN:  #{value['UNKNWN']}"
                msg.send(status_str)

getRegionInstances = (region, msg) ->
  ec2.setRegion(region).request 'DescribeInstances', (error, reservations) ->
    if error?
      msg.send "Failed to describe instances for region #{region} - error #{error}"
      return

    ec2.setRegion(region).request 'DescribeInstanceStatus', (error, allStatuses) ->
      statuses = if error? then [] else allStatuses.instanceStatusSet.item

      instances = _.flatten [reservations?.reservationSet?.item ? []]
      instances = _.pluck instances, 'instancesSet'
      instances = _.flatten _.pluck instances, 'item'

      msg.send "Found #{instances.length} instances for region #{region}..."

      for instance in instances
        do (instance) ->
          status = _.find statuses, (s) ->
            instance.instanceId == s.instanceId

          suffix = ''
          state = instance.instanceState.name
          excl = String.fromCharCode 0x203C
          dexcl = excl + excl
          if state == 'pending' or state == 'running' 
              switch state
                when 'pending' then prefix = String.fromCharCode 0x25B2
                when 'running' then prefix = String.fromCharCode 0x25BA
                when 'shutting-down' then prefix = String.fromCharCode 0x25BC
                when 'terminated' then prefix = String.fromCharCode 0x25AA
                when 'stopping' then prefix = String.fromCharCode 0x25A1
                when 'stopped' then prefix = String.fromCharCode 0x25A0
                else prefix = dexcl

              if status?
                bad = _.filter [status.systemStatus, status.instanceStatus],
                (s) -> s.status != 'ok'

                if bad.length > 0
                  prefix = dexcl
                  badStrings = _.map bad, (b) ->
                    b.details.item.name + ' ' + b.details.item.status
                  concat = (memo, s) -> memo + s
                  suffix = _.reduce badStrings, concat, ''

                iEvents = _.flatten [status.eventsSet?.item ? []]
                if not _.isEmpty iEvents then prefix = dexcl
                desc = (memo, e) -> "#{memo} #{dexcl}#{e.code} : #{e.description}"
                suffix += _.reduce iEvents, desc, ''

              id = instance.instanceId ? 'N/A'
              type = instance.instanceType
              dnsName = if _.isEmpty instance.dnsName then 'N/A' \
                else instance.dnsName
              launchTime = moment(instance.launchTime)
                .format 'ddd, L LT'
              arch = instance.architecture
              devType = instance.rootDeviceType

              tags = _.flatten [instance.tagSet.item]
              name_container = (_.find tags, (t) -> t.key == 'Name')
              if name_container != undefined then name = name_container.value else name = "Unknown name"
              msg.send "#{prefix} [#{state}] - #{name} / #{type} [#{devType} #{arch}] / #{dnsName} / #{region} / #{id} - started #{launchTime} #{suffix}"

getRegionQueues = (region, msg) ->
  sqs.setRegion(region).request 'ListQueues', {}, (error, queues) ->
    if error?
      msg.send 'Failed to list queues for region #{region} - error #{error}'
      return

    urls = _.flatten [queues.ListQueuesResult?.QueueUrl ? []]

    msg.send "Found #{urls.length} queues for region #{region}..."

    urls.forEach (url) ->

      url = url['#']
      name = url.split '/'
      name = name[name.length - 1]
      path = url.replace "https://sqs.#{region}.amazonaws.com", ''

      queue =
        Version: '2011-10-01'
        AttributeName: ['All']

      sqs.setRegion(region).setQueue(path + '/')
      .request 'GetQueueAttributes', queue, (error, attributes) ->
        if error?
          msg.send "Can't read queue attributes [#{name}] (path #{path})" +
            " - #{url} - #{error}"
          return

        info = attributes.GetQueueAttributesResult.Attribute
        for index, attr of info
          switch attr.Name
            when 'ApproximateNumberOfMessages' \
              then msgCount = attr.Value
            when 'ApproximateNumberOfMessagesNotVisible' \
              then inFlight = attr.Value

        queue.MaxNumberOfMessages = 1
        queue.VisibilityTimeout = 0

        sqs.setRegion(region).setQueue(path + '/')
        .request 'ReceiveMessage', queue, (error, result) ->

          queueDesc = "[SQS: #{name}] - [#{msgCount}] total msgs" +
            " / [#{inFlight}] in flight"
          if error?
            timestamp = "unavailable - #{error}"
          else
            sqsmsg = result.ReceiveMessageResult.Message
            if sqsmsg? and sqsmsg.Attribute?
              timestamp = (att for att in sqsmsg.Attribute \
                when att.Name == 'SentTimestamp')
              timestamp = (moment parseFloat timestamp[0].Value)
                .format 'ddd, L LT'
            else
              timestamp = 'none available'

          msg.send "#{queueDesc} / oldest msg ~[#{timestamp}] / #{url}"

defaultRegions = 'us-east-1,us-west-1,us-west-2,eu-west-1,ap-southeast-1,ap-northeast-1,sa-east-1'

module.exports = (robot) ->
  robot.respond /(^|\W)sqs status(\z|\W|$)/i, (msg) ->
    regions = process.env?.HUBOT_AWS_SQS_REGIONS ? defaultRegions
    getRegionQueues region, msg for region in regions.split ','
  robot.respond /(^|\W)ec2 status(\z|\W|$)/i, (msg) ->
    regions = process.env?.HUBOT_AWS_EC2_REGIONS ? defaultRegions
    getRegionInstances region, msg for region in regions.split ','
  robot.respond /(^|\W)emr status(\z|\W|$)/i, (msg) ->
    regions = process.env?.HUBOT_AWS_EC2_REGIONS ? defaultRegions
    getRegionEMRClusters region, msg for region in regions.split ','
