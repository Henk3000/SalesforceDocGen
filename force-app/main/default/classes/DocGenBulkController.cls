public with sharing class DocGenBulkController {

    /**
     * Returns all DocGen templates for the bulk generation UI.
     * @return List of DocGen_Template__c records ordered by name
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        return [SELECT Id, Name, Base_Object_API__c, Description__c, Output_Format__c, Query_Config__c, Test_Record_Id__c FROM DocGen_Template__c WITH SYSTEM_MODE ORDER BY Name];
    }

    /**
     * Validates a SOQL WHERE clause filter and returns the count of matching records.
     * @param objectName The SObject API name to query against
     * @param condition The WHERE clause condition to validate
     * @return The number of records matching the filter
     */
    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) { return 0; }
        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(objectName) == null) {
            throw new AuraHandledException('Invalid or inaccessible object.');
        }
        String sanitizedCondition = sanitizeCondition(condition);
        String query = 'SELECT Count() FROM ' + objectName;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';
        return Database.countQuery(query); // NOPMD ApexSOQLInjection - inputs validated by sanitizeCondition() which rejects SOQL keywords and dangerous chars; runs with USER_MODE
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     * Rejects conditions containing dangerous SOQL keywords that should never
     * appear in a WHERE clause fragment from the filter builder.
     */
    private static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) { return condition; }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw new AuraHandledException('Invalid filter condition.');
        }
        // Normalize whitespace for keyword matching (tabs, newlines, multiple spaces → single space)
        String normalized = condition.replaceAll('\\s+', ' ').toUpperCase().trim();
        // Reject conditions containing SOQL/DML keywords that don't belong in a WHERE clause
        List<String> disallowed = new List<String>{
            'SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'WITH ', 'GROUP BY ', 'ORDER BY ', 'LIMIT ', 'OFFSET ', 'FOR UPDATE',
            'HAVING ', 'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new AuraHandledException('Invalid filter condition.');
            }
        }
        return condition;
    }

    /**
     * Estimates the final heap usage for a merged PDF job based on a single sample record.
     * @param templateId The DocGen template record ID
     * @param recordCount Total number of records to be processed
     * @return HeapEstimate object with projected usage and risk status
     */
    @AuraEnabled
    public static HeapEstimate estimateHeapUsage(Id templateId, Integer recordCount) {
        HeapEstimate estimate = new HeapEstimate();
        if (templateId == null || recordCount == null || recordCount <= 0) {
            return estimate;
        }

        try {
            DocGen_Template__c temp = [SELECT Test_Record_Id__c FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1];
            if (String.isBlank(temp.Test_Record_Id__c)) {
                estimate.message = 'No test record ID on template. Estimation skipped.';
                return estimate;
            }

            // Generate HTML for one record
            String html = DocGenService.generateHtmlForRecord(templateId, temp.Test_Record_Id__c, null);
            
            // Apex characters are 2 bytes. 
            // Final heap will contain: 
            // 1. All snippet strings (already in ContentVersion, but read into memory)
            // 2. Concatenated fullHtml string
            // 3. pdfBlob (usually ~50-80% of HTML size, but safely assume 100%)
            // 4. Temporary processing overhead
            
            Long singleRecordBytes = html.length() * 2;
            Long totalProjectedBytes = singleRecordBytes * recordCount;
            
            // Add 25% safety buffer for overhead and concatenation
            Decimal totalMb = (totalProjectedBytes * 1.25) / (1024.0 * 1024.0);
            
            estimate.estimatedHeapMb = totalMb.setScale(2);
            // Async/Queueable heap limit is 12MB. Warn at 8MB, Risk at 10MB+.
            if (totalMb >= 10.0) {
                estimate.isRisk = true;
                estimate.message = 'High risk of Heap Limit failure (' + estimate.estimatedHeapMb + 'MB estimated). Consider reducing the record count or disabling Merge Mode.';
            } else if (totalMb >= 7.0) {
                estimate.isRisk = false; // Warning but allowed
                estimate.message = 'Moderate heap usage estimated (' + estimate.estimatedHeapMb + 'MB). Merge should succeed but monitor job status.';
            } else {
                estimate.isRisk = false;
                estimate.message = 'Heap usage estimated at ' + estimate.estimatedHeapMb + 'MB. Safe to proceed.';
            }
        } catch (Exception e) {
            estimate.message = 'Could not estimate heap: ' + e.getMessage();
        }
        return estimate;
    }

    public class HeapEstimate {
        @AuraEnabled public Decimal estimatedHeapMb;
        @AuraEnabled public Boolean isRisk = false;
        @AuraEnabled public String message;
    }

    /**
     * Submits a bulk document generation job for async processing.
     * @param templateId The DocGen template record ID
     * @param condition Optional SOQL WHERE clause to filter records
     * @param jobLabel Optional human-readable label for the job
     * @param mergePdf Whether to merge all outputs into a single PDF
     * @param batchSize Number of records per batch execution (1-200)
     * @param mergeOnly Whether to only generate merged PDF without individual files
     * @return The DocGen_Job__c record ID
     */
    @AuraEnabled
    public static Id submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly) {
        try {
            Boolean isMergeOnly = (mergeOnly == true);
            Boolean isMergeMode = (mergePdf == true) || isMergeOnly;

            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = templateId,
                Query_Condition__c = condition,
                Label__c = String.isNotBlank(jobLabel) ? jobLabel : null,
                Status__c = 'Queued',
                Merge_Only__c = isMergeOnly
            );
            // Package-internal object — CRUD controlled by DocGen permission sets
            insert job; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

            // 2. Run Batch — user-configurable batch size (default 1, max 200)
            Integer size = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
            DocGenBatch batch = new DocGenBatch(job.Id, isMergeMode, isMergeOnly);
            Database.executeBatch(batch, size);

            return job.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Error starting bulk generation job.');
        }
    }

    /**
     * Returns the current status and progress of a bulk generation job.
     * @param jobId The DocGen_Job__c record ID
     * @return The job record with status and count fields
     */
    @AuraEnabled
    public static DocGen_Job__c getJobStatus(Id jobId) {
        return [SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
    }

    /**
     * Returns the 20 most recent bulk generation jobs ordered by creation date.
     * @return List of DocGen_Job__c records with status and template info
     */
    @AuraEnabled
    public static List<DocGen_Job__c> getRecentJobs() {
        return [
            SELECT Id, Name, Label__c, Status__c, Success_Count__c, Error_Count__c, Total_Records__c,
                   CreatedDate, Template__r.Name, Template__r.Output_Format__c
            FROM DocGen_Job__c
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
    }

    /**
     * Returns ContentVersion IDs for PDFs generated by a completed bulk job.
     * Queries the same records the job processed, finds PDFs created after the job started.
     * @param jobId The DocGen_Job__c record ID
     * @return List of maps with 'label' (file title) and 'value' (ContentVersion ID)
     */
    @AuraEnabled
    public static List<Map<String, String>> getJobGeneratedPdfs(Id jobId) {
        DocGen_Job__c job = [
            SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Name,
                   Query_Condition__c, CreatedDate
            FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE
        ];

        String baseObject = job.Template__r.Base_Object_API__c;
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw new AuraHandledException('Invalid base object on job template.');
        }

        // Query the same records the batch processed
        String recQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
        String condition = sanitizeCondition(job.Query_Condition__c);
        if (String.isNotBlank(condition)) {
            recQuery += ' WHERE ' + condition;
        }
        recQuery += ' WITH USER_MODE LIMIT 2000';

        Set<Id> recordIds = new Set<Id>();
        for (SObject rec : Database.query(recQuery)) {
            recordIds.add(rec.Id);
        }

        if (recordIds.isEmpty()) { return new List<Map<String, String>>(); }

        // Find PDFs attached to those records created after the job was created
        Datetime jobStart = job.CreatedDate.addMinutes(-1);
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :recordIds
            AND ContentDocument.FileExtension = 'pdf'
            AND ContentDocument.CreatedDate >= :jobStart
            WITH SYSTEM_MODE
            ORDER BY ContentDocument.Title
        ];

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ContentDocumentLink link : links) {
            result.add(new Map<String, String>{
                'label' => link.ContentDocument.Title + '.pdf',
                'value' => link.ContentDocument.LatestPublishedVersionId
            });
        }
        return result;
    }

    // --- Saved Queries ---
    /**
     * Returns saved filter queries for a template, ordered by creation date descending.
     * @param templateId The DocGen template record ID
     * @return List of DocGen_Saved_Query__c records
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Saved_Query__c> getSavedQueries(Id templateId) {
        return [
            SELECT Id, Name, Description__c, Query_Condition__c
            FROM DocGen_Saved_Query__c
            WHERE DocGen_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Saves a named filter query for reuse with a template.
     * @param templateId The DocGen template record ID
     * @param label The display name for the saved query
     * @param description Optional description of the query
     * @param condition The SOQL WHERE clause condition
     */
    @AuraEnabled
    public static void saveQuery(Id templateId, String label, String description, String condition) {
        try {
            DocGen_Saved_Query__c sq = new DocGen_Saved_Query__c(
                DocGen_Template__c = templateId,
                Name = label,
                Description__c = description,
                Query_Condition__c = condition
            );
            // Package-internal object — CRUD controlled by DocGen permission sets
            insert sq; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets
        } catch (Exception e) {
            throw new AuraHandledException('Error saving query.');
        }
    }

    /**
     * Deletes a saved filter query.
     * @param queryId The DocGen_Saved_Query__c record ID to delete
     */
    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            if (!Schema.sObjectType.DocGen_Saved_Query__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Saved_Query__c(Id = queryId);
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting query.');
        }
    }
}