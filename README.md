# Objective
Unmount the workspace storage account previously mounted using the legacy mounting driver which has performance concerns and remount it using SMB with Managed Identity. This approach removes the dependency on storage account access keys and leverages Managed Identity for SMB (Preview).

# Reference:
[Use Managed Identities with Azure Files (preview) | Microsoft Learn](https://learn.microsoft.com/en-us/azure/storage/files/files-managed-identities?tabs=linux)

# Prerequisites

- Access to the workspace storage account
- Permission to create and assign User-Assigned Managed Identities
- Ability to create a new compute instance


# Setup Steps
1. Enable Managed Identity for SMB

- Go to the Storage Account
- Navigate to Settings → Configuration
- Set Managed Identity for SMB to Enabled


2. Create and Configure a User-Assigned Managed Identity

- Create a User-Assigned Managed Identity
- Assign the following roles on the workspace storage account:

- - Storage File Data Privileged Contributor
- - Storage Blob Data Contributor
- - Storage File Data SMB MI Admin




3. Update Script Configuration
Edit the config.env file in the script:

- `STORAGE_ACCOUNT` → Workspace storage account name
- `SHARE_NAME` → Code file share to be mounted to the compute instance
- Leave all other parameters unchanged


4. Create a Compute Instance

- Create a new compute instance
- Assign the User-Assigned Managed Identity created in Step 2


5. Run the Mount Script

Upload the azmount folder to your Notebooks
From the compute instance terminal, run:
```
bash setup.sh
```



Notes

- This setup is required once per compute instance
- A service is automatically created to persist the mount across restarts
- You should see improved performance, especially for operations like git clone
- This is an experimental, best-effort script

