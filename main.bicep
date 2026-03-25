// ================================================================
// CheckDiskSpace - Azure Logic App
// Reads Intune device inventory and adds devices with < 25 GB
// free disk space to an Entra ID group.
// ================================================================

@description('Name of the Logic App')
param logicAppName string = 'logic-check-disk-space'

@description('Azure region for the Logic App')
param location string = resourceGroup().location

@description('Object ID of the Entra ID source group containing the devices to check')
param sourceGroupObjectId string

@description('Object ID of the Entra ID destination group where low-disk devices will be added')
param entraGroupObjectId string

@description('Free disk space threshold in GB. Devices below this are added to the group.')
param thresholdGB int = 25

@description('Recurrence interval in hours')
param recurrenceIntervalHours int = 24

// Threshold in bytes (GB * 1024^3)
var thresholdBytes = thresholdGB * 1073741824

// ----------------------------------------------------------------
// Logic App with System-assigned Managed Identity
// ----------------------------------------------------------------
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        sourceGroupObjectId: {
          type: 'String'
          defaultValue: sourceGroupObjectId
        }
        entraGroupObjectId: {
          type: 'String'
          defaultValue: entraGroupObjectId
        }
        thresholdBytes: {
          type: 'Int'
          defaultValue: thresholdBytes
        }
      }
      triggers: {
        Recurrence: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Hour'
            interval: recurrenceIntervalHours
            timeZone: 'UTC'
          }
        }
      }
      actions: {
        // Paginate through device members of the source Entra group
        Initialize_NextLink: {
          type: 'InitializeVariable'
          runAfter: {}
          inputs: {
            variables: [
              {
                name: 'nextLink'
                type: 'string'
                value: 'https://graph.microsoft.com/v1.0/groups/@{parameters(\'sourceGroupObjectId\')}/members/microsoft.graph.device?$select=id,deviceId,displayName&$top=100'
              }
            ]
          }
        }
        Initialize_DevicesAdded: {
          type: 'InitializeVariable'
          runAfter: {
            Initialize_NextLink: ['Succeeded']
          }
          inputs: {
            variables: [
              {
                name: 'devicesAdded'
                type: 'integer'
                value: 0
              }
            ]
          }
        }
        Until_No_More_Pages: {
          type: 'Until'
          expression: '@equals(variables(\'nextLink\'), \'\')'
          limit: {
            count: 50
            timeout: 'PT1H'
          }
          runAfter: {
            Initialize_DevicesAdded: ['Succeeded']
          }
          actions: {
            Get_Group_Members_Page: {
              type: 'Http'
              inputs: {
                method: 'GET'
                uri: '@variables(\'nextLink\')'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://graph.microsoft.com'
                }
              }
            }
            Set_NextLink: {
              type: 'SetVariable'
              runAfter: {
                Get_Group_Members_Page: ['Succeeded']
              }
              inputs: {
                name: 'nextLink'
                value: '@{coalesce(body(\'Get_Group_Members_Page\')?[\'@odata.nextLink\'], \'\')}'
              }
            }
            For_Each_Device: {
              type: 'Foreach'
              runAfter: {
                Set_NextLink: ['Succeeded']
              }
              foreach: '@body(\'Get_Group_Members_Page\')?[\'value\']'
              actions: {
                // Look up the Intune managed device by azureADDeviceId (deviceId from Entra)
                Lookup_Intune_Device: {
                  type: 'Http'
                  inputs: {
                    method: 'GET'
                    uri: 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$filter=azureADDeviceId eq \'@{items(\'For_Each_Device\')?[\'deviceId\']}\'&$select=id,deviceName,freeStorageSpaceInBytes,azureADDeviceId'
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: 'https://graph.microsoft.com'
                    }
                  }
                }
                Check_Intune_Device_Found: {
                  type: 'If'
                  runAfter: {
                    Lookup_Intune_Device: ['Succeeded']
                  }
                  expression: {
                    and: [
                      {
                        greater: [
                          '@length(body(\'Lookup_Intune_Device\')?[\'value\'])'
                          0
                        ]
                      }
                    ]
                  }
                  actions: {
                    Check_Free_Space: {
                      type: 'If'
                      expression: {
                        and: [
                          {
                            greater: [
                              '@body(\'Lookup_Intune_Device\')?[\'value\'][0]?[\'freeStorageSpaceInBytes\']'
                              0
                            ]
                          }
                          {
                            less: [
                              '@body(\'Lookup_Intune_Device\')?[\'value\'][0]?[\'freeStorageSpaceInBytes\']'
                              '@parameters(\'thresholdBytes\')'
                            ]
                          }
                        ]
                      }
                      actions: {
                        Add_Device_To_Group: {
                          type: 'Http'
                          inputs: {
                            method: 'POST'
                            uri: 'https://graph.microsoft.com/v1.0/groups/@{parameters(\'entraGroupObjectId\')}/members/$ref'
                            headers: {
                              'Content-Type': 'application/json'
                            }
                            body: {
                              '@@odata.id': 'https://graph.microsoft.com/v1.0/directoryObjects/@{items(\'For_Each_Device\')?[\'id\']}'
                            }
                            authentication: {
                              type: 'ManagedServiceIdentity'
                              audience: 'https://graph.microsoft.com'
                            }
                          }
                        }
                        Increment_Counter: {
                          type: 'IncrementVariable'
                          runAfter: {
                            Add_Device_To_Group: ['Succeeded']
                          }
                          inputs: {
                            name: 'devicesAdded'
                            value: 1
                          }
                        }
                      }
                      else: {
                        actions: {}
                      }
                    }
                  }
                  else: {
                    actions: {}
                  }
                }
              }
              operationOptions: 'Sequential'
            }
          }
        }
      }
      outputs: {}
    }
  }
}

// ----------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------
output logicAppName string = logicApp.name
output logicAppId string = logicApp.id
output managedIdentityPrincipalId string = logicApp.identity.principalId
output managedIdentityTenantId string = logicApp.identity.tenantId
