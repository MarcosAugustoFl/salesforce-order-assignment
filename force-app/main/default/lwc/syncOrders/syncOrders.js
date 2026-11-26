import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import syncAccountOrders from '@salesforce/apex/OrdersSyncController.syncAccountOrders';

/**
 * Headless quick action on Account: starts a backfill of this account's orders from Orders.
 * The sync runs asynchronously, so the toast only confirms it started.
 */
export default class SyncOrders extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            await syncAccountOrders({ accountId: this.recordId });
            this.toast('success', 'Order sync started', 'Orders will appear in the External Orders list within a minute or two.');
        } catch (error) {
            this.toast('error', 'Could not start order sync', error?.body?.message ?? 'Unknown error');
        }
    }

    toast(variant, title, message) {
        this.dispatchEvent(new ShowToastEvent({ variant, title, message }));
    }
}
