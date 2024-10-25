# Declare variables (bash syntax)
export PREFIX="bot"
export RG_NAME="${PREFIX}-rg"
export VNET_NAME="${PREFIX}-vnet"
export SUBNET_INT_NAME="VnetIntegrationSubnet"
export SUBNET_PVT_NAME="PrivateEndpointSubnet"
export LOCATION="eastus2"
export TEAMS_IP_RANGE=("52.112.0.0/14" "52.122.0.0/15" "52.238.119.141/32" "52.244.160.207/32")
export FIREWALL_NAME="${LOCATION}-${PREFIX}-afw"
export USER_MI_NAME="${LOCATION}-${PREFIX}-identity"
export BOT_APP_NAME="bot1000001"

# Create a resource group
az group create --name ${RG_NAME} --location ${LOCATION}

# Create a virtual network with a subnet for the firewall
az network vnet create --name ${VNET_NAME} --resource-group ${RG_NAME} --location ${LOCATION} --address-prefix 10.0.0.0/16 --subnet-name AzureFirewallSubnet --subnet-prefix 10.0.1.0/26

# Add a subnet for the Virtual network integration
az network vnet subnet create --name ${SUBNET_INT_NAME} --resource-group ${RG_NAME} --vnet-name ${VNET_NAME} --address-prefix 10.0.2.0/24

# Add a subnet where the private endpoint will be deployed for the app service
az network vnet subnet create --name ${SUBNET_PVT_NAME} --resource-group ${RG_NAME} --vnet-name ${VNET_NAME} --address-prefix 10.0.3.0/24

# Create a firewall
az network firewall create --name ${FIREWALL_NAME} --resource-group ${RG_NAME} --location ${LOCATION}

# Create a public IP for the firewall
az network public-ip create --name ${FIREWALL_NAME}-pip --resource-group ${RG_NAME} --location ${LOCATION} --allocation-method static --sku standard

# Associate the IP with the firewall
az network firewall ip-config create --firewall-name ${FIREWALL_NAME} --name ${FIREWALL_NAME}-Config --public-ip-address ${FIREWALL_NAME}-pip --resource-group ${RG_NAME} --vnet-name ${VNET_NAME}

# Update the firewall
az network firewall update --name ${FIREWALL_NAME} --resource-group ${RG_NAME}

# Get the public IP address for the firewall and take note of it for later use
az network public-ip show --name ${FIREWALL_NAME}-pip --resource-group ${RG_NAME}

# Create identity
az identity create --resource-group ${RG_NAME} --name ${USER_MI_NAME}

# CLIENT_ID=$(az identity create --resource-group ${RG_NAME} --name ${USER_MI_NAME} --query 'clientId' --output tsv)
# echo "Client ID: $CLIENT_ID"

# Make sure to rename the ./bot/echo-bot/deploymentTemplates/parameters-for-template-AzureBot-with-rg.sample.json file to ./bot/echo-bot/deploymentTemplates/parameters-for-template-AzureBot-with-rg.json
# Make sure to rename the ./bot/echo-bot/deploymentTemplates/parameters-for-template-BotApp-with-rg.sample.json file to ./bot/echo-bot/deploymentTemplates/parameters-for-template-BotApp-with-rg.json
# Make sure to update the value in the above files as needed. The AppId is the client id of the managed identity created above.
# update parameters file with the client id before running the deployment
az deployment group create --resource-group ${RG_NAME} --template-file ./deploymentTemplates/template-BotApp-with-rg.json --parameters ./deploymentTemplates/parameters-for-template-BotApp-with-rg.json

# update parameters file with the client id before running the deployment
az deployment group create --resource-group ${RG_NAME} --template-file ./deploymentTemplates/template-AzureBot-with-rg.json --parameters ./deploymentTemplates/parameters-for-template-AzureBot-with-rg.json

# zip the bot, make sure its in the root of the folder (app.py, requirements.txt)
# deploy the bot
az webapp deploy --resource-group ${RG_NAME} --name ${BOT_APP_NAME} --src-path ./Archive.zip

# Disable private endpoint network policies (this step is not required if you're using the Azure portal)
az network vnet subnet update \
  --name ${SUBNET_PVT_NAME} \
  --resource-group ${RG_NAME} \
  --vnet-name ${VNET_NAME} \
  --disable-private-endpoint-network-policies true

# Create the private endpoint, being sure to copy the correct resource ID from your deployment of the bot app service
resource_id=$(az resource show --name ${BOT_APP_NAME} --resource-group ${RG_NAME} --resource-type Microsoft.web/sites --query "id" --output tsv)

az network private-endpoint create \
  --name pvt-${PREFIX}Endpoint \
  --resource-group ${RG_NAME} \
  --location ${LOCATION} \
  --vnet-name ${VNET_NAME} \
  --subnet ${SUBNET_PVT_NAME} \
  --connection-name conn-${PREFIX} \
  --private-connection-resource-id ${resource_id} \
  --group-id sites

# Create a private DNS zone to resolve the name of the app service
az network private-dns zone create \
  --name ${PREFIX}privatelink.azurewebsites.net \
  --resource-group ${RG_NAME}

az network private-dns link vnet create \
  --name ${PREFIX}-DNSLink \
  --resource-group ${RG_NAME} \
  --registration-enabled false \
  --virtual-network ${VNET_NAME} \
  --zone-name ${PREFIX}privatelink.azurewebsites.net

az network private-endpoint dns-zone-group create \
  --name chatBotZoneGroup \
  --resource-group ${RG_NAME} \
  --endpoint-name pvt-${PREFIX}Endpoint \
  --private-dns-zone ${PREFIX}privatelink.azurewebsites.net \
  --zone-name ${PREFIX}privatelink.azurewebsites.net

# Establish virtual network integration for outbound traffic
az webapp vnet-integration add \
  -g ${RG_NAME} \
  -n ${BOT_APP_NAME} \
  --vnet ${VNET_NAME} \
  --subnet ${SUBNET_INT_NAME}


  # Create a route table
az network route-table create \
  -g ${RG_NAME} \
  -n rt-${PREFIX}RouteTable

# Create a default route with 0.0.0.0/0 prefix and the next hop as the Azure firewall virtual appliance to inspect all traffic.
private_firewall_ip=$(az network private-endpoint show --name pvt-${PREFIX}Endpoint --resource-group ${RG_NAME} --query "customDnsConfigs[0].ipAddresses" --output tsv)
az network route-table route create -g ${RG_NAME} \
  --route-table-name rt-${PREFIX}RouteTable -n default \
  --next-hop-type VirtualAppliance \
  --address-prefix 0.0.0.0/0 \
  --next-hop-ip-address ${private_firewall_ip}

# Associate the two subnets with the route table
az network vnet subnet update -g ${RG_NAME} \
  -n ${SUBNET_INT_NAME} \
  --vnet-name ${VNET_NAME} \
  --route-table rt-${PREFIX}RouteTable

az network vnet subnet update -g ${RG_NAME} \
  -n ${SUBNET_PVT_NAME} \
  --vnet-name ${VNET_NAME} \
  --route-table rt-${PREFIX}RouteTable

# Create a NAT rule collection and a single rule. The source address is the public IP range of Microsoft Teams
# Destination address is that of the firewall.
# The translated address is that of the app service's private link.
public_firewall_ip=$(az network public-ip show --resource-group ${RG_NAME} --name ${FIREWALL_NAME}-pip --query "ipAddress" --output tsv)
az network firewall nat-rule create \
  --resource-group ${RG_NAME} \
  --collection-name coll-${PREFIX}-nat-rules \
  --priority 200 \
  --action DNAT \
  --source-addresses ${TEAMS_IP_RANGE} \
  --dest-addr ${firewall_internal_ip} \
  --destination-ports 443 \
  --firewall-name ${FIREWALL_NAME} \
  --name rl-ip2appservice \
  --protocols TCP \
  --translated-address ${public_firewall_ip} \
  --translated-port 443

# Create a network rule collection and add four rules to it.
# The first one is an outbound network rule to only allow traffic to the Teams IP range.
# The source address is that of the virtual network address space, destination is the Teams IP range.
az network firewall network-rule create \
  --resource-group ${RG_NAME} \
  --collection-name coll-${PREFIX}-network-rules \
  --priority 200 \
  --action Allow \
  --source-addresses 10.0.0.0/16 \
  --dest-addr ${TEAMS_IP_RANGE} \
  --destination-ports 443 \
  --firewall-name ${FIREWALL_NAME} \
  --name rl-OutboundTeamsTraffic \
  --protocols TCP

# This rule will enable traffic to all IP addresses associated with Azure AD service tag
az network firewall network-rule create \
  --resource-group ${RG_NAME} \
  --collection-name coll-${PREFIX}-network-rules \
  --source-addresses 10.0.0.0/16 \
  --dest-addr AzureActiveDirectory \
  --destination-ports '*' \
  --firewall-name ${FIREWALL_NAME} \
  --name rl-AzureAD \
  --protocols TCP

# This rule will enable traffic to all IP addresses associated with Azure Bot Services service tag
az network firewall network-rule create \
  --resource-group ${RG_NAME} \
  --collection-name coll-${PREFIX}-network-rules \
  --source-addresses 10.0.0.0/16 \
  --dest-addr AzureBotService \
  --destination-ports '*' \
  --firewall-name ${FIREWALL_NAME} \
  --name rl-AzureBotService \
  --protocols TCP

# This rule will enable traffic the bot framework login  endpoint
az network firewall application-rule create \
  --resource-group ${RG_NAME} \
  --collection-name coll-${PREFIX}-application-rules \
  --source-addresses 10.0.0.0/16 \
  --protocols "https=443" \
  --target-fqdns "login.botframework.com" \
  --firewall-name ${FIREWALL_NAME} \
  --name rl-Bots \
  --priority 200 \
  --action "Allow"

  # Cleanup
  az group delete --name ${RG_NAME} --no-wait --yes