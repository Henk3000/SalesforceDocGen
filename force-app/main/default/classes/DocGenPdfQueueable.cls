/**
 * Queueable that generates a PDF via Blob.toPdf() in a callout-enabled context.
 * Blob.toPdf() can only fetch images from Salesforce URLs when running in a
 * Queueable/Batch context (not @AuraEnabled), so all PDF generation with images
 * must be routed through this Queueable.
 *
 * Supports two modes:
 * - Save to record (resultKey is null): saves PDF as ContentVersion linked to the record
 * - Download result (resultKey is set): saves PDF as a temporary ContentVersion
 *   that the LWC can poll for and download
 */
public without sharing class DocGenPdfQueueable implements Queueable, Database.AllowsCallouts {

    private Id templateId;
    private Id recordId;
    private String batchKey;
    private String docTitle;
    private String resultKey;

    /**
     * Constructor for save-to-record mode.
     */
    public DocGenPdfQueueable(Id templateId, Id recordId, String batchKey, String docTitle) {
        this.templateId = templateId;
        this.recordId = recordId;
        this.batchKey = batchKey;
        this.docTitle = docTitle;
        this.resultKey = null;
    }

    /**
     * Constructor for download mode — saves PDF as temp CV identified by resultKey.
     */
    public DocGenPdfQueueable(Id templateId, Id recordId, String batchKey, String docTitle, String resultKey) {
        this.templateId = templateId;
        this.recordId = recordId;
        this.batchKey = batchKey;
        this.docTitle = docTitle;
        this.resultKey = resultKey;
    }

    public void execute(QueueableContext context) {
        try {
            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.toPdf('<html><body><p>Test PDF</p></body></html>');
            } else {
                pdfBlob = DocGenService.generatePdfFromBatch(templateId, recordId, batchKey);
            }

            if (String.isNotBlank(resultKey)) {
                // Download mode: save as temp CV for LWC to poll and download
                ContentVersion cv = new ContentVersion();
                cv.Title = 'docgen_result_' + resultKey;
                cv.PathOnClient = (docTitle != null ? docTitle : 'Document') + '.pdf';
                cv.VersionData = pdfBlob;
                insert cv;
            } else {
                // Save-to-record mode: save PDF linked to the record
                ContentVersion cv = new ContentVersion();
                String baseName = docTitle != null ? docTitle : 'Generated_Document';
                cv.Title = baseName;
                cv.PathOnClient = baseName + '.pdf';
                cv.VersionData = pdfBlob;
                cv.FirstPublishLocationId = recordId;
                insert cv;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: PDF Queueable error: ' + e.getMessage());
        } finally {
            if (String.isNotBlank(batchKey)) {
                DocGenService.cleanupTempImages(batchKey);
            }
        }
    }
}
