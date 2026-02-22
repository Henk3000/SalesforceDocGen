public with sharing class DocGenRenditionQueueable implements Queueable, Database.AllowsCallouts {
    
    private List<Id> cvIds;
    private Integer retryCount;
    
    public DocGenRenditionQueueable(Id cvId) {
        this(new List<Id>{cvId}, 0);
    }

    public DocGenRenditionQueueable(List<Id> cvIds) {
        this(cvIds, 0);
    }
    
    public DocGenRenditionQueueable(List<Id> cvIds, Integer retryCount) {
        this.cvIds = cvIds;
        this.retryCount = retryCount;
    }
    
    public void execute(QueueableContext context) {
        List<Id> failedIds = new List<Id>();
        List<ContentVersion> cvsToInsert = new List<ContentVersion>();
        List<Id> successSourceIds = new List<Id>();
        
        for (Id cvId : cvIds) {
            try {
                ContentVersion pdfCv = DocGenRenditionService.capturePdfRendition(cvId);
                if (pdfCv != null) {
                    cvsToInsert.add(pdfCv);
                    successSourceIds.add(cvId);
                    System.debug('DocGen Rendition Collected for CV: ' + cvId);
                }
            } catch (DocGenRenditionService.RenditionException e) {
                if (e.getMessage().contains('Rendition not ready')) {
                    failedIds.add(cvId);
                } else {
                    System.debug('DocGen Rendition Failure for ' + cvId + ': ' + e.getMessage());
                }
            } catch (Exception e) {
                System.debug('DocGen Rendition Unexpected Error for ' + cvId + ': ' + e.getMessage());
            }
        }

        // Bulk insert collected renditions
        if (!cvsToInsert.isEmpty()) {
            try {
                insert cvsToInsert;
                System.debug('DocGen: Bulk inserted ' + cvsToInsert.size() + ' renditions.');
                
                // CLEANUP: Delete the temporary source DOCX/PPTX files
                // We do this in the same async context but with partial success allowed
                cleanupSourceFiles(successSourceIds);
            } catch (Exception e) {
                System.debug('DocGen Rendition Insert Error: ' + e.getMessage());
                // If the insert failed due to a lock, add all back to failedIds for a clean retry later
                failedIds.addAll(successSourceIds);
            }
        }

        // Handle retries in a separate transaction (wait 1 minute for locks to clear)
        if (!failedIds.isEmpty() && retryCount < 3) {
            if (!Test.isRunningTest()) {
                System.enqueueJob(new DocGenRenditionQueueable(failedIds, retryCount + 1));
            }
        }
    }

    /**
     * Deletes the source ContentDocument records of successfully captured PDFs.
     * Uses partial success (allOrNone=false) so cleanup errors don't kill the transaction.
     */
    private void cleanupSourceFiles(List<Id> sourceCvIds) {
        if (sourceCvIds.isEmpty()) return;
        try {
            List<ContentVersion> sources = [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :sourceCvIds];
            Set<Id> docIds = new Set<Id>();
            for (ContentVersion cv : sources) {
                docIds.add(cv.ContentDocumentId);
            }
            if (!docIds.isEmpty()) {
                List<ContentDocument> toDelete = new List<ContentDocument>();
                for (Id docId : docIds) {
                    toDelete.add(new ContentDocument(Id = docId));
                }
                // Partial success: if a document is locked, skip it; it will be a stray but won't crash the job
                Database.delete(toDelete, false);
                System.debug('DocGen Cleanup: Attempted deletion of ' + toDelete.size() + ' source documents.');
            }
        } catch (Exception e) {
            System.debug('DocGen Cleanup Error: ' + e.getMessage());
        }
    }
}
