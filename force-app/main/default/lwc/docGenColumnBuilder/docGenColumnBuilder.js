import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import getAvailableReports from '@salesforce/apex/DocGenController.getAvailableReports';
import importReportConfig from '@salesforce/apex/DocGenController.importReportConfig';

let _colId = 0;
function nextColId() { return 'col_' + (_colId++); }

export default class DocGenColumnBuilder extends LightningElement {
    // === PUBLIC API ===
    @api selectedObject = '';
    @api
    get queryConfig() { return this._queryConfig; }
    set queryConfig(value) {
        this._queryConfig = value;
        if (value) this._parseConfig(value);
    }
    _queryConfig = '';

    // === CORE STATE: objectColumns ===
    @track objectColumns = [];
    @track objectOptions = [];
    @track isLoaded = false;

    // Object picker
    @track showObjectPicker = false;
    @track objectSearchTerm = '';
    @track selectedObjectLabel = '';

    // Add column picker
    @track showAddPicker = false;
    @track childRelOptions = [];
    @track addPickerSearch = '';

    // Report import
    @track showReportModal = false;
    @track reportSearchResults = [];
    @track reportSearchTerm = '';
    @track selectedReportId = null;
    @track selectedReportName = '';
    @track isImportingReport = false;
    @track showImportPreview = false;
    @track importPreviewData = null;

    // === WIRE: Object list ===
    @wire(getObjectOptions)
    wiredObjects({ data }) {
        if (data) {
            this.objectOptions = data;
            this.isLoaded = true;
            if (this.selectedObject) {
                const opt = data.find(o => o.value === this.selectedObject);
                if (opt) this.selectedObjectLabel = opt.label;
                // Auto-init base column if object is set but no columns exist
                if (this.objectColumns.length === 0) {
                    this._initBaseColumn(this.selectedObject, this.selectedObjectLabel);
                }
            }
        }
    }

    // === COMPUTED ===

    get hasColumns() { return this.objectColumns.length > 0; }

    get baseColumn() { return this.objectColumns.find(c => c.role === 'base'); }

    get filteredObjectOptions() {
        const term = (this.objectSearchTerm || '').toLowerCase();
        return this.objectOptions.filter(o => o.label.toLowerCase().includes(term)).slice(0, 50);
    }

    get filteredAddOptions() {
        const term = (this.addPickerSearch || '').toLowerCase();
        return this.childRelOptions.filter(o => o.label.toLowerCase().includes(term));
    }

    get showObjectSelector() {
        return !this.selectedObject && !this.hasColumns;
    }

    // === JSON V2 CONFIG OUTPUT ===

    get generatedConfig() {
        const base = this.baseColumn;
        if (!base || base.selectedFields.length === 0) return '';

        const config = {
            v: 2,
            baseObject: this.selectedObject,
            baseFields: [...base.selectedFields],
            parentFields: [],
            children: [],
            junctions: [],
            reportFilters: []
        };

        // Parent fields from base column's parentGroups
        if (base.parentGroups) {
            for (const pg of base.parentGroups) {
                for (const f of pg.fields) {
                    config.parentFields.push(pg.relationshipName + '.' + f);
                }
            }
        }

        // Children and junctions from other columns
        for (const col of this.objectColumns) {
            if (col.role === 'child') {
                config.children.push({
                    rel: col.relationshipName,
                    fields: [...col.selectedFields],
                    where: col.whereClause || '',
                    orderBy: col.orderBy || '',
                    limit: col.limitAmount || ''
                });
            } else if (col.role === 'junction' && col.junctionConfig) {
                config.junctions.push({
                    junctionRel: col.junctionConfig.junctionRel,
                    junctionFields: col.junctionConfig.junctionFields || [],
                    targetObject: col.junctionConfig.targetObject,
                    targetIdField: col.junctionConfig.targetIdField,
                    targetFields: [...col.selectedFields],
                    targetWhere: col.whereClause || '',
                    targetOrderBy: col.orderBy || ''
                });
            }
        }

        return JSON.stringify(config);
    }

    // === OBJECT SELECTION ===

    handleObjectSearch(event) {
        this.objectSearchTerm = event.target.value;
        this.showObjectPicker = true;
    }

    handleObjectFocus() {
        this.showObjectPicker = true;
    }

    handleObjectSelect(event) {
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.selectedObject = value;
        this.selectedObjectLabel = label;
        this.showObjectPicker = false;
        this._initBaseColumn(value, label);
    }

    _initBaseColumn(objectApiName, label) {
        // Create the base column and load its fields
        const col = this._createColumn('base', objectApiName, label || objectApiName, null);
        this.objectColumns = [col];
        this._loadColumnFields(col);
        this._loadChildRelationships(objectApiName);
        this._notifyChange();
    }

    // === COLUMN MANAGEMENT ===

    _createColumn(role, objectApiName, label, relationshipName, junctionConfig) {
        const baseLabel = this.selectedObjectLabel || this.selectedObject || '';
        let subtitle = '';
        if (role === 'child') {
            subtitle = 'Related to: ' + baseLabel;
        } else if (role === 'junction' && junctionConfig) {
            subtitle = 'Linked via: ' + (junctionConfig.junctionRel || '');
        }

        return {
            id: nextColId(),
            objectApiName,
            label,
            subtitle,
            role,
            relationshipName: relationshipName || null,
            junctionConfig: junctionConfig || null,
            selectedFields: [],
            parentGroups: role === 'base' ? [] : undefined,
            whereClause: '',
            orderBy: '',
            limitAmount: '',
            availableFields: [],
            filteredFields: [],
            fieldSearch: '',
            badgeClass: role === 'base' ? 'badge-base badge-main' :
                        role === 'junction' ? 'badge-base badge-linked' : 'badge-base badge-related',
            badgeLabel: role === 'base' ? 'Main Record' :
                        role === 'junction' ? 'Linked Records' : 'Related List',
            isBase: role === 'base',
            isNotBase: role !== 'base',
            hasSubtitle: role !== 'base'
        };
    }

    _loadColumnFields(col) {
        getObjectFields({ objectName: col.objectApiName })
            .then(data => {
                col.availableFields = data;
                col.filteredFields = data.slice(0, 200);
                this.objectColumns = [...this.objectColumns];
            });
    }

    _loadChildRelationships(objectApiName) {
        getChildRelationships({ objectName: objectApiName })
            .then(data => {
                this.childRelOptions = data.map(r => ({
                    ...r,
                    type: 'child',
                    displayLabel: r.label
                }));
                // TODO: Also detect junction paths and add to options
            });
    }

    handleAddColumn() {
        this.showAddPicker = true;
        this.addPickerSearch = '';
    }

    handleAddPickerSearch(event) {
        this.addPickerSearch = event.target.value;
    }

    handleAddPickerSelect(event) {
        const relName = event.currentTarget.dataset.value;
        const opt = this.childRelOptions.find(o => o.value === relName);
        if (!opt) return;

        this.showAddPicker = false;

        // Don't add duplicates
        if (this.objectColumns.find(c => c.relationshipName === relName)) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Already added', message: opt.label + ' is already in your template.', variant: 'warning' }));
            return;
        }

        const col = this._createColumn('child', opt.childObjectApiName, opt.label, relName);
        this.objectColumns = [...this.objectColumns, col];
        this._loadColumnFields(col);
        this._notifyChange();
    }

    handleCloseAddPicker() {
        this.showAddPicker = false;
    }

    handleRemoveColumn(event) {
        const colId = event.currentTarget.dataset.colId;
        this.objectColumns = this.objectColumns.filter(c => c.id !== colId);
        this._notifyChange();
    }

    // === FIELD SELECTION ===

    handleFieldChange(event) {
        const colId = event.target.dataset.colId;
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) {
            col.selectedFields = event.detail.value;
            this.objectColumns = [...this.objectColumns];
            this._notifyChange();
        }
    }

    handleFieldSearch(event) {
        const colId = event.target.dataset.colId;
        const search = event.target.value.toLowerCase();
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) {
            col.filteredFields = col.availableFields.filter(f =>
                f.label.toLowerCase().includes(search)
            ).slice(0, 200);
            this.objectColumns = [...this.objectColumns];
        }
    }

    handleSelectAll(event) {
        const colId = event.target.dataset.colId;
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) {
            const allVals = col.filteredFields.map(f => f.value);
            const current = new Set(col.selectedFields);
            const allSelected = allVals.every(v => current.has(v));
            col.selectedFields = allSelected ? [] : allVals;
            this.objectColumns = [...this.objectColumns];
            this._notifyChange();
        }
    }

    handleWhereChange(event) {
        const colId = event.target.dataset.colId;
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) { col.whereClause = event.detail.value; this._notifyChange(); }
    }

    handleOrderChange(event) {
        const colId = event.target.dataset.colId;
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) { col.orderBy = event.detail.value; this._notifyChange(); }
    }

    handleLimitChange(event) {
        const colId = event.target.dataset.colId;
        const col = this.objectColumns.find(c => c.id === colId);
        if (col) { col.limitAmount = event.detail.value; this._notifyChange(); }
    }

    // === REPORT IMPORT ===

    handleOpenReportImport() {
        this.showReportModal = true;
        this.reportSearchResults = [];
        this.reportSearchTerm = '';
        this.selectedReportId = null;
        this.selectedReportName = '';
        this.showImportPreview = false;
        this._searchReports('');
    }

    handleCloseReportModal() {
        this.showReportModal = false;
        this.showImportPreview = false;
    }

    handleReportSearch(event) {
        const term = event.target.value;
        this.reportSearchTerm = term;
        clearTimeout(this._reportSearchTimeout);
        this._reportSearchTimeout = setTimeout(() => this._searchReports(term), 300);
    }

    _searchReports(term) {
        getAvailableReports({ searchTerm: term })
            .then(data => {
                this.reportSearchResults = data.map(r => ({
                    ...r,
                    isSelected: r.id === this.selectedReportId,
                    optionClass: 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small' +
                        (r.id === this.selectedReportId ? ' slds-theme_shade' : '')
                }));
            })
            .catch(() => { this.reportSearchResults = []; });
    }

    handleReportSelect(event) {
        this.selectedReportId = event.currentTarget.dataset.id;
        this.selectedReportName = event.currentTarget.dataset.name;
        this.reportSearchResults = this.reportSearchResults.map(r => ({
            ...r,
            isSelected: r.id === this.selectedReportId,
            optionClass: 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small' +
                (r.id === this.selectedReportId ? ' slds-theme_shade' : '')
        }));
    }

    get isImportDisabled() { return !this.selectedReportId || this.isImportingReport; }

    handleImportReport() {
        if (!this.selectedReportId) return;
        this.isImportingReport = true;

        importReportConfig({ reportId: this.selectedReportId })
            .then(result => {
                // Show preview step
                this.importPreviewData = result;
                this.showImportPreview = true;
                this.isImportingReport = false;
            })
            .catch(error => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Import Failed',
                    message: error.body ? error.body.message : error.message,
                    variant: 'error'
                }));
                this.isImportingReport = false;
            });
    }

    handleConfirmImport() {
        const result = this.importPreviewData;
        if (!result) return;

        this.showReportModal = false;
        this.showImportPreview = false;

        // Set the base object
        this.selectedObject = result.baseObject;
        const objOpt = this.objectOptions.find(o => o.value === result.baseObject);
        this.selectedObjectLabel = objOpt ? objOpt.label : result.baseObject;

        // Build columns from the import result
        const columns = [];

        // Base column
        const baseCol = this._createColumn('base', result.baseObject, this.selectedObjectLabel, null);
        columns.push(baseCol);

        // Load fields for base, then auto-check the imported ones
        getObjectFields({ objectName: result.baseObject })
            .then(data => {
                baseCol.availableFields = data;
                baseCol.filteredFields = data.slice(0, 200);

                // Auto-check imported base fields
                const validFields = new Set(data.map(f => f.value));
                baseCol.selectedFields = (result.fields || []).filter(f => validFields.has(f));

                // Set parent fields
                if (result.parentFields && result.parentFields.length > 0) {
                    // Group parent fields by relationship name
                    const groups = {};
                    for (const pf of result.parentFields) {
                        const parts = pf.split('.');
                        const rel = parts[0];
                        const field = parts.slice(1).join('.');
                        if (!groups[rel]) groups[rel] = { relationshipName: rel, fields: [] };
                        groups[rel].fields.push(field);
                    }
                    baseCol.parentGroups = Object.values(groups);
                }

                this.objectColumns = [...columns];
                this._notifyChange();
            });

        // Load child relationships for the "Add Related Records" picker
        this._loadChildRelationships(result.baseObject);

        // Add child columns from childSubqueries
        if (result.childSubqueries) {
            // Parse subqueries and create columns — for now just track the relationship names
            // The childFields map has relName → [fieldNames]
        }
        if (result.childFields) {
            const childFieldsMap = result.childFields;
            for (const relName of Object.keys(childFieldsMap)) {
                if (relName.startsWith('__junction_')) continue; // Handle separately
                const fields = childFieldsMap[relName];
                // We need the child object name — load from child rel options after they load
                getChildRelationships({ objectName: result.baseObject })
                    .then(rels => {
                        const rel = rels.find(r => r.value === relName);
                        if (rel) {
                            const childCol = this._createColumn('child', rel.childObjectApiName, rel.label, relName);
                            getObjectFields({ objectName: rel.childObjectApiName })
                                .then(fieldData => {
                                    childCol.availableFields = fieldData;
                                    childCol.filteredFields = fieldData.slice(0, 200);
                                    const validChildFields = new Set(fieldData.map(f => f.value));
                                    childCol.selectedFields = fields.filter(f => validChildFields.has(f));
                                    this.objectColumns = [...this.objectColumns, childCol];
                                    this._notifyChange();
                                });
                        }
                    });
            }
        }

        this.dispatchEvent(new ShowToastEvent({
            title: 'Report Imported',
            message: 'Fields from "' + result.reportName + '" have been applied to your template.',
            variant: 'success'
        }));
    }

    // === CONFIG PARSING ===

    _parseConfig(value) {
        if (!value) return;
        const trimmed = value.trim();

        if (trimmed.startsWith('{')) {
            this._parseJsonConfig(trimmed);
        } else {
            this._parseLegacyConfig(trimmed);
        }
    }

    _parseJsonConfig(jsonStr) {
        try {
            const config = JSON.parse(jsonStr);
            if (!config.baseObject) return;

            this.selectedObject = config.baseObject;
            const objOpt = this.objectOptions.find(o => o.value === config.baseObject);
            this.selectedObjectLabel = objOpt ? objOpt.label : config.baseObject;

            const columns = [];

            // Base column
            const baseCol = this._createColumn('base', config.baseObject, this.selectedObjectLabel, null);
            baseCol.selectedFields = config.baseFields || [];
            if (config.parentFields) {
                const groups = {};
                for (const pf of config.parentFields) {
                    const parts = pf.split('.');
                    const rel = parts[0];
                    const field = parts.slice(1).join('.');
                    if (!groups[rel]) groups[rel] = { relationshipName: rel, fields: [] };
                    groups[rel].fields.push(field);
                }
                baseCol.parentGroups = Object.values(groups);
            }
            columns.push(baseCol);
            this._loadColumnFields(baseCol);

            // Children
            if (config.children) {
                for (const child of config.children) {
                    const childCol = this._createColumn('child', '', child.rel, child.rel);
                    childCol.selectedFields = child.fields || [];
                    childCol.whereClause = child.where || '';
                    childCol.orderBy = child.orderBy || '';
                    childCol.limitAmount = child.limit || '';
                    columns.push(childCol);
                    // Load child object name and fields
                    getChildRelationships({ objectName: config.baseObject })
                        .then(rels => {
                            const rel = rels.find(r => r.value === child.rel);
                            if (rel) {
                                childCol.objectApiName = rel.childObjectApiName;
                                childCol.label = rel.label;
                                this._loadColumnFields(childCol);
                            }
                        });
                }
            }

            // Junctions
            if (config.junctions) {
                for (const j of config.junctions) {
                    const jCol = this._createColumn('junction', j.targetObject,
                        j.targetObject + ' (via ' + j.junctionRel + ')', j.junctionRel,
                        { junctionRel: j.junctionRel, junctionFields: j.junctionFields || [],
                          targetObject: j.targetObject, targetIdField: j.targetIdField });
                    jCol.selectedFields = j.targetFields || [];
                    jCol.whereClause = j.targetWhere || '';
                    jCol.orderBy = j.targetOrderBy || '';
                    columns.push(jCol);
                    this._loadColumnFields(jCol);
                }
            }

            this.objectColumns = columns;
            this._loadChildRelationships(config.baseObject);

        } catch (e) {
            console.error('DocGen: Failed to parse JSON config', e);
        }
    }

    _parseLegacyConfig(configStr) {
        // For legacy configs, init base column and set selectedObject
        // The parent component should handle this via the existing query builder
        // This is a minimal bridge — full legacy parsing would need the old component
        if (!this.selectedObject) return;
        this._initBaseColumn(this.selectedObject, this.selectedObjectLabel);
    }

    // === NOTIFY PARENT ===

    _notifyChange() {
        this.dispatchEvent(new CustomEvent('configchange', {
            detail: {
                objectName: this.selectedObject,
                queryConfig: this.generatedConfig
            }
        }));
    }
}
