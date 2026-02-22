public with sharing class DocGenRenditionService {
    
    public class RenditionException extends Exception {}

    private static List<Id> cvIdsCollector = new List<Id>();

    /**
     * Adds a ContentVersion ID to the collection for later rendition capture.
     */
    public static void addPendingRendition(Id cvId) {
        cvIdsCollector.add(cvId);
    }

    /**
     * Enqueues a single background job for all collected ContentVersion IDs.
     */
    public static void enqueueRenditions() {
        if (cvIdsCollector.isEmpty()) return;
        
        if (!Test.isRunningTest()) {
            System.enqueueJob(new DocGenRenditionQueueable(new List<Id>(cvIdsCollector)));
        }
        cvIdsCollector.clear();
    }

    /**
     * Attempts to retrieve a PDF rendition for a given ContentVersion ID.
     * Returns a new (unsaved) ContentVersion record containing the PDF data.
     */
    public static ContentVersion capturePdfRendition(Id cvId) {
        ContentVersion cv = [SELECT ContentDocumentId, Title, PathOnClient FROM ContentVersion WHERE Id = :cvId LIMIT 1];
        String fileId = cv.ContentDocumentId;
        
        // Use VF page to get a full Session ID for the background job
        String sessionId = !Test.isRunningTest() ? Page.DocGenSessionProvider.getContent().toString().trim() : 'test_session_id';
        
        // Endpoint for PDF Rendition (Dynamic Loopback instead of hardcoded Named Credential)
        String endpoint = Url.getOrgDomainUrl().toExternalForm() + '/services/data/v65.0/connect/files/' + fileId + '/rendition?type=PDF';
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        
        Http h = new Http();
        HttpResponse res = h.send(req);
        
        if (res.getStatusCode() == 200) {
            Blob pdfBlob = res.getBodyAsBlob();
            
            ContentVersion pdfCv = new ContentVersion();
            pdfCv.Title = cv.Title + ' (PDF)';
            pdfCv.PathOnClient = cv.Title + '.pdf';
            pdfCv.VersionData = pdfBlob;
            pdfCv.FirstPublishLocationId = findRecordId(cv.ContentDocumentId);
            
            return pdfCv;
        } else if (res.getStatusCode() == 202 || res.getStatusCode() == 404 || res.getStatusCode() == 301 || res.getStatusCode() == 302) {
            throw new RenditionException('Rendition not ready yet (Status: ' + res.getStatusCode() + '). Retrying...');
        } else {
            throw new RenditionException('Failed to capture rendition: ' + res.getStatusCode() + ' ' + res.getStatus() + ' ' + res.getBody());
        }
    }

    private static Id findRecordId(Id docId) {
        List<ContentDocumentLink> links = [SELECT LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId = :docId AND LinkedEntityId != :UserInfo.getUserId() LIMIT 1];
        return links.isEmpty() ? null : links[0].LinkedEntityId;
    }
}
