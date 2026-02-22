public class LoopbackTestQueueable implements Queueable, Database.AllowsCallouts {
    private String sessionId;
    public LoopbackTestQueueable(String sid) {
        this.sessionId = sid;
    }
    public void execute(QueueableContext context) {
        String endpoint = Url.getOrgDomainUrl().toExternalForm() + '/services/data/v65.0/query/?q=SELECT+Id+FROM+Account+LIMIT+1';
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + this.sessionId);
        
        Http h = new Http();
        HttpResponse res = h.send(req);
        System.debug('Queueable Loopback Status: ' + res.getStatusCode());
        System.debug('Queueable Loopback Body: ' + res.getBody());
    }
}
