# Installation & Setup Guide

This document outlines the simplified installation process for the **Agentforce Document Generation** package.

## Step 1: Install the Package
1. Log into your Salesforce org (Production, Sandbox, or Developer Edition).
2. Click the installation link below:
   👉 **[Install DocGen version 0.1.0-4](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Nos9QAC)**
3. Select **Install for Admins Only** (or specify profiles as needed).
4. Click **Install**.

## Step 2: Assign Permission Sets
Ensure that users who will manage templates or generate documents have the appropriate permission sets assigned:
- **DocGen Admin**: Full access to template management, bulk generation runs, and saved queries.
- **DocGen User**: Standard access for generating documents from existing templates.

## Configuration Note
*No manual configuration is required!* 

The package dynamically handles secure, background PDF renditions using your org's native REST API. There is no need to configure Named Credentials or Remote Site Settings. It works out-of-the-box in any deployed environment.
