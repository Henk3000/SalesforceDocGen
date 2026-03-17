public without sharing class DocGenSignatureService {

    public class SignatureException extends Exception {}

    /**
     * Injects a Base64 PNG image into an existing DOCX ContentVersion and returns the Blob without inserting to DB.
     * This is used by the Hybrid Flow to get stamped content for client-side PDF rendering.
     */
    public static Blob stampSignatureToBlob(Id sourceCvId, String base64Image, String requestNumber) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Blob signatureBlob = EncodingUtil.base64Decode(base64Image);
        
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        String imageRelId = 'rIdSig' + String.valueOf(System.currentTimeMillis()).substring(8);
        String imageFileName = 'signature_' + imageRelId + '.jpeg';

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="jpeg"') && !contentTypes.contains('Extension="jpg"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                String newRel = '<Relationship Id="' + imageRelId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + imageFileName + '"/>';
                rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();
                String drawingXml = 
                    '<w:r><w:drawing>' +
                      '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                        '<wp:extent cx="1905000" cy="476250"/>' +
                        '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                        '<wp:docPr id="888" name="Signature"/>' +
                        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                          '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                              '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                              '<pic:blipFill>' +
                                '<a:blip r:embed="' + imageRelId + '"/>' +
                                '<a:stretch><a:fillRect/></a:stretch>' +
                              '</pic:blipFill>' +
                              '<pic:spPr>' +
                                '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                              '</pic:spPr>' +
                            '</pic:pic>' +
                          '</a:graphicData>' +
                        '</a:graphic>' +
                      '</wp:inline>' +
                    '</w:drawing></w:r>';

                if (docXml.contains('{#Signature}')) {
                    docXml = docXml.replace('{#Signature}', '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                } else {
                    docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">Signature: </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        writer.addEntry('word/media/' + imageFileName, signatureBlob);
        return writer.getArchive();
    }

    /**
     * Data wrapper for multi-signer stamping.
     */
    public class SignerData {
        public String roleName;
        public String base64Image;
        public SignerData(String roleName, String base64Image) {
            this.roleName = roleName;
            this.base64Image = base64Image;
        }
    }

    /**
     * Stamps ALL signer signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {#Signature_RoleName} in the document.
     * Falls back to legacy {#Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Build per-signer metadata: relationship IDs, file names, blobs
        List<Map<String, String>> signerMeta = new List<Map<String, String>>();
        List<Blob> signerBlobs = new List<Blob>();
        Integer docPrIdBase = 888;

        for (Integer i = 0; i < signers.size(); i++) {
            SignerData sd = signers[i];
            String relId = 'rIdSig' + String.valueOf(i) + String.valueOf(System.currentTimeMillis()).right(5);
            String fileName = 'signature_' + relId + '.jpeg';
            // Build placeholder tag: blank role → {#Signature}, otherwise {#Signature_RoleName}
            String placeholder;
            if (String.isBlank(sd.roleName)) {
                placeholder = '{#Signature}';
            } else {
                placeholder = '{#Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
            }
            Map<String, String> meta = new Map<String, String>{
                'relId' => relId,
                'fileName' => fileName,
                'placeholder' => placeholder,
                'docPrId' => String.valueOf(docPrIdBase + i)
            };
            signerMeta.add(meta);
            signerBlobs.add(EncodingUtil.base64Decode(sd.base64Image));
        }

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="jpeg"') && !contentTypes.contains('Extension="jpg"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                for (Map<String, String> meta : signerMeta) {
                    String newRel = '<Relationship Id="' + meta.get('relId') + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + meta.get('fileName') + '"/>';
                    rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                }
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();

                for (Map<String, String> meta : signerMeta) {
                    String drawingXml =
                        '<w:r><w:drawing>' +
                          '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                            '<wp:extent cx="1905000" cy="476250"/>' +
                            '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                            '<wp:docPr id="' + meta.get('docPrId') + '" name="Signature"/>' +
                            '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                              '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                  '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                                  '<pic:blipFill>' +
                                    '<a:blip r:embed="' + meta.get('relId') + '"/>' +
                                    '<a:stretch><a:fillRect/></a:stretch>' +
                                  '</pic:blipFill>' +
                                  '<pic:spPr>' +
                                    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                                  '</pic:spPr>' +
                                '</pic:pic>' +
                              '</a:graphicData>' +
                            '</a:graphic>' +
                          '</wp:inline>' +
                        '</w:drawing></w:r>';

                    String placeholder = meta.get('placeholder');
                    if (docXml.contains(placeholder)) {
                        docXml = docXml.replace(placeholder, '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                    } else {
                        // Append at end of document as fallback
                        docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">' + placeholder.substringBetween('{#', '}') + ': </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                    }
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        // Add all signature images
        for (Integer i = 0; i < signerMeta.size(); i++) {
            writer.addEntry('word/media/' + signerMeta[i].get('fileName'), signerBlobs[i]);
        }

        return writer.getArchive();
    }

    /**
     * Stamping legacy entry point - inserts the DOCX to DB and returns ID.
     */
    public static Id stampSignature(Id sourceCvId, String base64Image, String requestNumber, String relatedRecordId) {
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        Blob resultBlob = stampSignatureToBlob(sourceCvId, base64Image, requestNumber);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ newCv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            insert cdlDecision.getRecords();
        }

        return savedCvId;
    }

    /**
     * @description Privileged entry point called by Flow invocable actions.
     * Saves signature data, then enqueues PDF generation in a separate transaction
     * to avoid DML-before-callout (getContentAsPDF is a callout).
     */
    public static void handleSignatureSubmission(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new SignatureException('Invalid security token format.');
        }

        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c, CreatedDate
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            return;
        }

        // Token expiration: 30 days
        if (requests[0].CreatedDate.addDays(30) < System.now()) {
            throw new SignatureException('This signature link has expired.');
        }

        DocGen_Signature_Request__c req = requests[0];

        // Transaction 1: Save signature image to request record (DML)
        req.Signature_Data__c = base64Image;
        req.Status__c = 'In Progress';
        update req;

        // Transaction 2: Enqueue PDF generation (callout) in a separate transaction.
        // In test context, getContentAsPDF() doesn't work, so simulate completion inline.
        if (Test.isRunningTest()) {
            try {
                Blob pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
                List<ContentVersion> sources = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = !sources.isEmpty() ? sources[0].Title + ' - Signed' : 'Document - Signed';
                DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, EncodingUtil.base64Encode(pdfBlob), 'pdf');
                req.Status__c = 'Signed';
                req.Signature_Data__c = null;
                update req;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Test path signature error: ' + e.getMessage());
            }
        } else {
            System.enqueueJob(new SignaturePdfQueueable(req.Id));
        }
    }

    /**
     * Stage 1 Queueable: Stamps signatures into DOCX, extracts images from the
     * stamped document, saves them as temporary ContentVersion records, then chains
     * Stage 2 to render the PDF. Two stages are needed because Flying Saucer (the PDF
     * renderer) can only fetch images from committed ContentVersion records.
     */
    public class SignaturePdfQueueable implements Queueable {
        private Id requestId;

        public SignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (requests.isEmpty()) return;

            DocGen_Signature_Request__c req = requests[0];

            try {
                // Stamp all signatures into the DOCX
                List<DocGen_Signer__c> signers = [
                    SELECT Role_Name__c, Signature_Data__c
                    FROM DocGen_Signer__c
                    WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                    WITH SYSTEM_MODE
                    ORDER BY Sort_Order__c ASC
                ];

                Blob stampedBlob;
                if (!signers.isEmpty()) {
                    List<DocGenSignatureService.SignerData> signerDataList = new List<DocGenSignatureService.SignerData>();
                    for (DocGen_Signer__c s : signers) {
                        signerDataList.add(new DocGenSignatureService.SignerData(s.Role_Name__c, s.Signature_Data__c));
                    }
                    stampedBlob = DocGenSignatureService.stampAllSignaturesToBlob(req.Source_Document_Id__c, signerDataList);
                } else {
                    // Legacy single-signer
                    DocGen_Signature_Request__c fullReq = [
                        SELECT Signature_Data__c FROM DocGen_Signature_Request__c
                        WHERE Id = :requestId WITH SYSTEM_MODE LIMIT 1
                    ];
                    if (String.isNotBlank(fullReq.Signature_Data__c)) {
                        stampedBlob = DocGenSignatureService.stampSignatureToBlob(
                            req.Source_Document_Id__c, fullReq.Signature_Data__c, String.valueOf(requestId)
                        );
                    }
                }

                if (stampedBlob == null) {
                    req.Status__c = 'Viewed';
                    Database.update(req, false, AccessLevel.SYSTEM_MODE);
                    return;
                }

                // Extract images from stamped DOCX and save as temp ContentVersion records
                String batchKey = EncodingUtil.convertToHex(
                    Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(System.now().getTime()) + Math.random()))
                ).substring(0, 32);

                Map<String, Object> parts = DocGenSignatureController.extractDocxParts(stampedBlob);
                Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

                List<ContentVersion> tempImages = new List<ContentVersion>();
                if (imagesByRelId != null && !imagesByRelId.isEmpty()) {
                    for (String relId : imagesByRelId.keySet()) {
                        String base64 = imagesByRelId.get(relId);
                        String ext = (base64.startsWith('/9j/') || base64.startsWith('/9J/')) ? 'jpeg' : 'png';
                        ContentVersion cv = new ContentVersion();
                        cv.Title = 'docgen_sig_' + batchKey + '_' + relId;
                        cv.PathOnClient = 'docgen_sig_' + batchKey + '_' + relId + '.' + ext;
                        cv.VersionData = EncodingUtil.base64Decode(base64);
                        tempImages.add(cv);
                    }
                    insert tempImages;
                }

                // Save stamped DOCX XML as temp CV (so stage 2 doesn't need to re-stamp)
                String documentXml = (String) parts.get('documentXml');
                if (documentXml != null) {
                    ContentVersion xmlCv = new ContentVersion();
                    xmlCv.Title = 'docgen_sig_' + batchKey + '_xml';
                    xmlCv.PathOnClient = 'docgen_sig_' + batchKey + '_xml.txt';
                    xmlCv.VersionData = Blob.valueOf(documentXml);
                    insert xmlCv;
                }

                // Chain stage 2 to render PDF (images will be committed when this execute() ends)
                System.enqueueJob(new SignaturePdfRenderQueueable(requestId, batchKey));

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Signature stamp failed for request ' + req.Id + ': ' + e.getMessage());
                req.Status__c = 'Viewed';
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }
    }

    /**
     * Stage 2 Queueable: Renders the signed PDF using pre-saved image ContentVersion
     * records (from Stage 1), saves the PDF, creates audit trail, and marks as Signed.
     */
    public class SignaturePdfRenderQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;
        private String batchKey;

        public SignaturePdfRenderQueueable(Id requestId, String batchKey) {
            this.requestId = requestId;
            this.batchKey = batchKey;
        }

        public void execute(QueueableContext ctx) {
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (requests.isEmpty()) return;

            DocGen_Signature_Request__c req = requests[0];

            try {
                // Read the saved document XML
                List<ContentVersion> xmlCvs = [
                    SELECT Id, VersionData FROM ContentVersion
                    WHERE Title = :('docgen_sig_' + batchKey + '_xml')
                    WITH SYSTEM_MODE LIMIT 1
                ];
                if (xmlCvs.isEmpty()) {
                    throw new SignatureException('Stamped document XML not found for batch: ' + batchKey);
                }
                String documentXml = xmlCvs[0].VersionData.toString();

                // Build URL-based image map from pre-saved temp CVs
                Map<String, String> imageUrlMap = new Map<String, String>();
                String prefix = 'docgen_sig_' + batchKey + '_';
                List<ContentVersion> imgCvs = [
                    SELECT Id, Title FROM ContentVersion
                    WHERE Title LIKE :(prefix + '%') AND Title != :('docgen_sig_' + batchKey + '_xml')
                    WITH SYSTEM_MODE
                ];
                for (ContentVersion cv : imgCvs) {
                    String relId = cv.Title.substring(prefix.length());
                    imageUrlMap.put(relId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
                }

                // Generate HTML with URL-based images and render PDF via Blob.toPdf()
                String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);

                Blob pdfBlob;
                if (Test.isRunningTest()) {
                    pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed</p></body></html>');
                } else {
                    pdfBlob = Blob.toPdf(html);
                }

                // Save PDF to record
                ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
                String fileName = source.Title + ' - Signed';
                String base64Pdf = EncodingUtil.base64Encode(pdfBlob);
                DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');

                // Create audit trail
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
                audit.Signature_Request__c = req.Id;
                audit.Signer_Name__c = req.Signer_Name__c;
                audit.Signer_Email__c = req.Signer_Email__c;
                audit.Signed_Date__c = System.now();
                audit.Document_Hash_SHA256__c = pdfHash;
                audit.IP_Address__c = 'Server-Side';
                audit.User_Agent__c = 'VF renderAs=pdf - Server-Side PDF Generation';
                Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

                // Mark Request as Signed, clear signature data
                req.Status__c = 'Signed';
                req.Signature_Data__c = null;
                Database.update(req, false, AccessLevel.SYSTEM_MODE);

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: PDF render failed for request ' + req.Id + ': ' + e.getMessage());
                req.Status__c = 'Viewed';
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            } finally {
                // Clean up all temp CVs for this batch
                cleanupSignatureTempImages(batchKey);
            }
        }

        private void cleanupSignatureTempImages(String bKey) {
            try {
                List<ContentVersion> tempCvs = [
                    SELECT ContentDocumentId FROM ContentVersion
                    WHERE Title LIKE :('docgen_sig_' + bKey + '_%')
                    WITH SYSTEM_MODE
                ];
                if (!tempCvs.isEmpty()) {
                    Set<Id> docIds = new Set<Id>();
                    for (ContentVersion cv : tempCvs) {
                        docIds.add(cv.ContentDocumentId);
                    }
                    delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Failed to clean up temp signature images: ' + e.getMessage());
            }
        }
    }
}