List<ContentVersion> cvs = [SELECT Id FROM ContentVersion WHERE FileExtension = 'docx' LIMIT 2];
List<Id> ids = new List<Id>();
for(ContentVersion cv : cvs) ids.add(cv.Id);
if(!ids.isEmpty()){
    System.enqueueJob(new DocGenRenditionQueueable(ids));
    System.debug('Targeted Fix Test Enqueued for ' + ids.size() + ' files.');
}
